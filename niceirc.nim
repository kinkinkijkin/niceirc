import asyncnet, asyncdispatch, streams, os, strutils

#Configuration type, for storing configuration from a file.
type
    ConfigServ* = object
        var isCalled*, nick*, username*, realname*,
        pass*, servAddr*: string
        var servPort*: int = 6667
        var reqPass*: bool = false
    
    ClientInfo* = object
        var name, channel: string
        var ssock, csock: AsyncSocket
        var instream, outstream: StringStream

#Currently connected servers and loaded configurations
var clients: seq[ClientInfo]
var serverconfs: seq[ConfigServ]

#Make lines for the UI client. Currently very simple, to be extended in the future
proc makeUILine(line, senderName: string): string =
    result = "< " & senderName & " > " & line
    return result

#Send lines to the UI client
proc sendInLines(c: ClientInfo) {.async.} =
    while not c.instream.atEnd():
        var l = c.instream.readLine()
        var ol: string
        var fromNick = l.splitWhitespace()[0]
        l.removePrefix(fromNick)
        ol = makeUILine(l & "\n", fromNick)
        await c.csock.send(ol)

#Sort through messages to only show what's relevant and implemented
proc messageFilterAndUI(mesg: string, c: ClientInfo) {.async.} =
    if mesg.contains("PRIVMSG") and mesg.splitWhitespace[2].contains(c.channel):
        var body = mesg.split(':')[3]
        var sender = mesg.split('!')[0]
        sender.removePrefix(":")
        c.instream.writeLine(sender & " " & body)

#Recieve messages from the server and add to processing list
proc getInFromServer(server: AsyncSocket, sname: string, lstream: StringStream) {.async.} =
    while true:
        let line = await server.recvLine()
        if line.len == 0: break
        else:
            lstream.writeLine(line)


#Open communications with client UI
proc openClientUi(cui: var AsyncSocket, s: ConfigServ, cn: string) {.async.} =
    cui = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    var sockname = ".nicesock-" & cn
    await bindUnix(cui, getHomeDir() & sockname)
    await cui.send("Client UI socket opened for " & cn & " at " & sockname)

#Open the IPC interface for clients to request new clients to be made on
proc openClientListener(clist: var AsyncSocket) {.async.} =
    clist = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    await bindUnix(clist, getHomeDir() & ".nicesockMAST")

#Open communications with server
proc openCommunications(server: var AsyncSocket, s: ConfigServ, msg: var string) {.async.} =
    msg = "Connecting to " & s.isCalled
    server = await dial(s.servAddr, s.servPort.Port)
    msg = msg & "\nConnected to " & s.isCalled & " has succeeded"
    if s.reqPass:
        await server.send("PASS " & s.pass)
    msg = msg & "\nRegistering connection with nick " & s.nick
    await server.send("NICK " & s.nick)
    await server.send("USER " & s.username & " 0 * :" & s.realname)
    msg = msg & "\nPassoff from server opening proc"

#Initialize the UI client's relevant data and start connections
proc startClient(chname, clidesignator: string, server: ConfigServ): ClientInfo =
    result = new ClientInfo
    result.instream = newStringStream("")
    result.outstream = newStreamStream("")
    result.channel = chname
    result.name = clidesignator

    var messages1 = ""

    await openClientUi(result.csock, server, result.name)
    await openCommunications(result.ssock, server, messages1)



var nClientListener: AsyncSocket

await openClientListener(nClientListener)