import asyncnet, asyncdispatch, streams, os, strutils

type
    #Configuration type, for storing configuration from a file.
    ConfigServ* = object
        var isCalled*, nick*, username*, realname*,
        pass*, servAddr*: string
        var servPort*: int = 6667
        var reqPass*: bool = false
    #Type for a current running client
    ClientInfo* = object
        var name*, channel*: string
        var ssock*, csock*: AsyncSocket
        var instream*, outstream*: StringStream
    #Type for storing which servers are already open, and what clients they send to
    ClientInfoList* = object
        var serverName*: string
        var clientRefs*: seq[ref ClientInfo]
        var sock*: ref AsyncSocket #Convenience member

#Currently connected servers and loaded configurations
var clients: seq[ClientInfo]
var serverconfs: seq[ConfigServ]
var connectedservs: seq[ClientInfoList] = @[]

#Make lines for the UI client. Currently very simple, to be extended in the future
proc makeUILine(line, senderName: string): string =
    result = "< " & senderName & " > " & line
    return result

#Send lines to the UI client
proc sendInLines() {.async.} =
    for c in clients:
        while not c.instream.atEnd():
            var l = c.instream.readLine()
            var ol: string
            var fromNick = l.splitWhitespace()[0]
            l.removePrefix(fromNick)
            ol = makeUILine(l & "\n", fromNick)
            await c.csock.send(ol)
        c.instream.flush()

proc sendOutLines() {.async.} =
    for c in clients:
        while not c.outstream.atEnd():
            var l = c.outstream.readLine()
            var fl: string
            fl = "PRIVMSG " & c.channel & " :" & line
            c.ssock.send(fl)
        c.instream.flush()

#Sort through messages to only show what's relevant and implemented
proc messageFilterAndUI(mesg: string, c: ClientInfo) {.async.} =
    #Internal daemon-ui messages
    if mesg.startsWith("internal"):
        var body = mesg
        body.removePrefix("internal")
        c.instream.writeLine("DAEMON " & body)
        return
    #Channel and private messages
    elif mesg.contains("PRIVMSG"):
        var body = mesg.split(':')[3]
        var sender = mesg.split('!')[0]
        sender.removePrefix(":")
        c.instream.writeLine(sender & " " & body)
        return

#Open communications with client UI
proc openClientUi(cui: var AsyncSocket, s: ConfigServ, cn: string) {.async.} =
    cui = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    var sockname = ".nicesock-" & cn
    await bindUnix(cui, getHomeDir() & sockname)
    await cui.send("Client UI socket opened for " & cn & " at " & sockname)

proc closeClientUi(c: ClientInfo) =
    c.csock.close()
    c.ssock.close()

#Open the IPC interface for clients to request new clients to be made on
proc openClientListener(clist: var AsyncSocket) {.async.} =
    clist = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    await bindUnix(clist, getHomeDir() & ".nicesockMAST")
    clist.listen()

proc closeClientListener(clist: var AsyncSocket) =
    await close(clist)

#Open communications with server
proc openCommunications(client: var ClientInfo, s: ConfigServ, msg: var string) {.async.} =
    var check: bool
    block performCheck:
        for cs in connectedservs:
            if s.isCalled == cs.serverName:
                check = true
                client.ssock = cs.sock[]
                break performCheck
    if not check: 
        msg = "Connecting to " & s.isCalled
        client.ssock = await dial(s.servAddr, s.servPort.Port)
        msg = msg & "\nConnecting to " & s.isCalled & " has succeeded"
        if s.reqPass:
            await client.ssock.send("PASS " & s.pass)
        msg = msg & "\nRegistering connection with nick " & s.nick
        await client.ssock.send("NICK " & s.nick)
        await client.ssock.send("USER " & s.username & " 0 * :" & s.realname)
        msg = msg & "\nPassoff from server opening proc"
        connectedservs.add((s.isCalled, @[ref client[]], ref client[].ssock))
    else:
        msg = "Server already open, passing on to channel connection\n"
        connectedservs.clientRefs.add(ref client[])

proc closeDaemon(clist: AsyncSocket) = 
    for server in connectedservs:
        for uiclient in server.clientRefs:
            uiclient.closeClientUi()
    connectedservs.free()
    serverconfs.free()
    closeClientListener(clist)
    quit(0)

#Initialize the UI client's relevant data and start connections
proc startClient(chname, clidesignator: string, server: ConfigServ): ClientInfo =
    result = new ClientInfo
    result.instream = newStringStream("")
    result.outstream = newStreamStream("")
    result.channel = chname
    result.name = clidesignator

    var messages1 = ""

    await openClientUi(result.csock, server, result.name)
    await openCommunications(result, server, messages1)
    await messageFilterAndUI(messages1, result)
    await result.sendInLines()

    return result


var nClientListener: AsyncSocket

await openClientListener(nClientListener)

#Listen for client requests
proc clientListen() {.async.} = 
    while true:
        var reader: string = await nClientListener.readLine()
        var readerSplit: seq[string] = reader.splitWhitespace()
        var thisClient = new ClientInfo
        var serverMatch: bool = false
        if readerSplit[0] == "STOP":
            closeDaemon(nClientListener)
        elif readerSplit[0] == "NEW":
            #Parsing state machine. Can be done better. Don't care.
            var thisNewServ: ConfigServ = new ConfigServ
            for confline in lines(readerSplit[1]):
                if confline.startsWith("CALLED:"):
                    var tmp1 = confline
                    tmp1.removePrefix("CALLED:")
                    thisNewServ.isCalled = tmp1
                elif confline.startsWith("NICK:"):
                    var tmp1 = confline
                    tmp1.removePrefix("NICK:")
                    thisNewServ.nick = tmp1
                elif confline.startsWith("USERNAME:"):
                    var tmp1 = confline
                    tmp1.removePrefix("USERNAME:")
                    thisNewServ.username = tmp1
               elif confline.startsWith("REALNAME:"):
                    var tmp1 = confline
                    tmp1.removePrefix("REALNAME:")
                    thisNewServ.realname = tmp1
                elif confline.startsWith("PASSREQ:"):
                    var tmp1 = confline
                    tmp1.removePrefix("PASSREQ:")
                    thisNewServ.reqPass = tmp1.parseBool()
                elif confline.startsWith("PASS:"):
                    var tmp1 = confline
                    tmp1.removePrefix("PASS:")
                    thisNewServ.pass = tmp1
                elif confline.startsWith("ADDR:"):
                    var tmp1 = confline
                    tmp1.removePrefix("ADDR:")
                    thisNewServ.servAddr = tmp1
                elif confline.startsWith("PORT:"):
                    var tmp1 = confline
                    tmp1.removePrefix("PORT:")
                    thisNewServ.port = tmp1.parseInt
            
            block servCheck:
                for se in serverconfs:
                    if thisNewServ.isCalled == se.isCalled:
                        serverMatch = true
                        break servCheck
            if serverMatch:
                #If the server is currently connected to, open client and add it to that server
                var thisClient = startClient(readerSplit[2], readerSplit[3], thisNewServ)
                for i in connectedservs.len:
                    if connectedservs[i].serverName == thisNewServ.name
                        connectedservs[i].clientRefs.add(ref thisClient)
                        clients.add(thisClient)
            else:
                #If the server isn't connected to yet, add server to the list while opening
                var thisClient = startClient(readerSplit[2], readerSplit[3], thisNewServ)
                serverconfs.add(thisNewServ)
                var newServer: ClientInfoList = new ClientInfoList
                newServer.serverName = thisNewServ.name
                newServer.clientRefs.add(ref thisClient)
                clients.add(thisClient)
                newServer.sock = ref thisClient.ssock
                connectedservs.add(newServer)

asyncCheck clientListen()

#Checks if servers have sent anything our way
proc checkServers() {.async.} =
    for s in connectedservs:
        var msgFromServer = await s.sock.recvLine()
        if not (msgFromServer.len == 0):
            if msgFromServer.contains("PRIVMSG"):
                for cli in s.clientRefs:
                    if msgFromServer.splitWhitespace()[2] == cli[].channel:
                        await messageFilterAndUI(msgFromServer, cli[])

asyncCheck checkServers()

#Checks if the clients have anything to send to their servers
proc checkBuffers() {.async.} =
    for c in clients:
        var msgForServer = await c.csock.recvLine()
        if not (msgForServer.len == 0):
            c.outstream.writeLine(msgForServer)

asyncCheck checkBuffers()

#Continuously runs the send procs
proc middleManProc() {.async.} =
    while true:
        asyncCheck sendInLines()
        asyncCheck sendOutLines()

asyncCheck middleManProc()