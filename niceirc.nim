import asyncnet, asyncdispatch, net, streams, os, strutils

type
    #Configuration type, for storing configuration from a file.
    ConfigServ* = object
        isCalled*, nick*, username*, realname*,
            pass*, servAddr*: string
        bnicks: seq[string]
        servPort*: int
        reqPass*: bool
    #Type for a current running client
    ClientInfo* = object
        name*, channel*: string
        csock*: AsyncSocket
        instream*, outstream*: StringStream
    #Type for storing which servers are already open, and what clients they send to
    ClientInfoList* = object
        serverName*: string
        clientRefs*: seq[ClientInfo]
        sock*: AsyncSocket #Convenience member

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
    for s in connectedservs:
        for c in s.clientRefs:
            while not c.outstream.atEnd():
                var l = c.outstream.readLine()
                var fl: string
                fl = "PRIVMSG " & c.channel & " :" & l
                await s.sock.send(fl)
            c.outstream.flush()

#Sort through messages to only show what's relevant and implemented
proc messageFilterAndUI(mesg: string, c: ClientInfo) {.async.} =
    #Internal daemon-ui messages
    if mesg.startsWith("internal"):
        var body = mesg
        body.removePrefix("internal")
        c.instream.writeLine("DAEMON " & body & "\n")
        return
    #Channel and private messages
    elif mesg.contains("PRIVMSG"):
        var body = mesg.split(':')[3]
        var sender = mesg.split('!')[0]
        sender.removePrefix(":")
        c.instream.writeLine(sender & " " & body & "\n")
        return
    else:
        c.instream.writeLine(mesg & "\n")

#Open communications with client UI
proc openClientUi(cui: AsyncSocket, s: ConfigServ, cn: string): Future[AsyncSocket] {.async.} =
    var sockname = "/.nicesock-" & cn
    if not tryRemoveFile(getHomeDir() & sockname):
        echo "client socket exists and cannot be removed"
        quit(22)
    cui.bindUnix(getHomeDir() & sockname)
    cui.listen()
    return await cui.accept()

proc closeClientUi(c: ClientInfo) =
    c.csock.close()

#Open the IPC interface for clients to request new clients to be made on
proc openClientListener(clist: AsyncSocket) {.async.} =
    clist.listen()

proc closeClientListener(clist: var AsyncSocket) =
    close(clist)

#Open communications with server
proc openCommunications(client: ClientInfo, s: ConfigServ): Future[AsyncSocket] {.async.} =
    var check: bool
    block performCheck:
        for cs in connectedservs:
            if s.isCalled == cs.serverName:
                check = true
                break performCheck
    if not check: 
        var clinfo: ClientInfoList
        clinfo.sock = await asyncnet.dial(s.servAddr, s.servPort.Port, buffered = true)
        if s.reqPass:
            await clinfo.sock.send("PASS " & s.pass)
        await clinfo.sock.send("NICK " & s.nick)
        await clinfo.sock.send("USER " & s.username & " 0 * :" & s.realname)
        clinfo.serverName = s.isCalled
        clinfo.clientRefs = @[client]
        connectedservs.add(clinfo)
        return clinfo.sock
    else:
        for i in 0..(connectedservs.len-1):
            if s.isCalled == connectedservs[i].serverName:
                connectedservs[i].clientRefs.add(client)
                return connectedservs[i].sock
        

proc closeDaemon(clist: var AsyncSocket) = 
    for server in connectedservs:
        for uiclient in server.clientRefs:
            uiclient.closeClientUi()
    closeClientListener(clist)
    quit(0)

#Initialize the UI client's relevant data and start connections
proc startClient(chname, clidesignator: string, server: ConfigServ): ClientInfo =
    var result: ClientInfo
    result.instream = newStringStream("")
    result.outstream = newStringStream("")
    result.channel = chname
    result.name = clidesignator
    var tmpsock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

    var messages1 = ""

    result.csock = waitFor openClientUi(tmpsock, server, result.name)
    var tmpsock2 = waitFor openCommunications(result, server)
    waitFor messageFilterAndUI(messages1, result)
    waitFor sendInLines()
    waitFor tmpsock2.send("JOIN " & result.channel)

    return result


var nClientListener: AsyncSocket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

#Try to clear the sockfile if it exists, fail if it exists and we can't remove it
if not tryRemoveFile(getHomeDir() & "/.nicesockMAST"):
    echo "master socket file exists and cannot be removed. \"~/.nicesockMAST\" is its name."
    quit(22)

nClientListener.bindUnix(getHomeDir() & "/.nicesockMAST")

nClientListener.listen()

#Listen for client requests
proc clientListen(onepass: bool) {.async.} = 
    while true:
        var newsock = await nClientListener.accept()
        echo "accepted"
        var reader: string = await newsock.recvLine()
        echo reader
        var readerSplit: seq[string] = reader.splitWhitespace()
        var thisClient = new ClientInfo
        var serverMatch: bool = false
        if readerSplit[0] == "STOP":
            closeDaemon(nClientListener)
        elif readerSplit[0].startsWith("NEW"):
            #Parsing state machine. Can be done better. Don't care.
            var thisNewServ: ConfigServ
            for confline in lines(readerSplit[1]):
                if confline.startsWith("CALLED:"):
                    var tmp1 = confline
                    tmp1.removePrefix("CALLED:")
                    thisNewServ.isCalled = tmp1
                elif confline.startsWith("NICK:"):
                    var tmp1 = confline
                    tmp1.removePrefix("NICK:")
                    thisNewServ.nick = tmp1
                elif confline.startsWith("BNICK:"):
                    var tmp1 = confline
                    tmp1.removePrefix("BNICK:")
                    thisNewServ.bnicks.add(tmp1)
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
                    thisNewServ.servPort = tmp1.parseInt

            block servCheck:
                for se in serverconfs:
                    if thisNewServ.isCalled == se.isCalled:
                        serverMatch = true
                        break servCheck
            if serverMatch:
                #If the server is currently connected to, open client and add it to that server
                var thisClient = startClient(readerSplit[2], readerSplit[3], thisNewServ)
                for i in 0..(connectedservs.len-1):
                    if connectedservs[i].serverName == thisNewServ.isCalled:
                        connectedservs[i].clientRefs.add(thisClient)
                        clients.add(thisClient)
            else:
                #If the server isn't connected to yet, add server to the list while opening
                var thisClient = startClient(readerSplit[2], readerSplit[3], thisNewServ)
                serverconfs.add(thisNewServ)
                var newServer: ClientInfoList
                newServer.serverName = thisNewServ.isCalled
                newServer.clientRefs.add(thisClient)
                clients.add(thisClient)
        if onepass: break

waitFor clientListen(true)

#Checks if servers have sent anything our way
proc checkServers() {.async.} =
    while true:
        for s in connectedservs:
            var msgFromServer = await s.sock.recvLine()
            if not (msgFromServer.len == 0):
#                if msgFromServer.contains("PRIVMSG"):
                for cli in s.clientRefs:
                    if msgFromServer.splitWhitespace()[2] == cli.channel:
                        await messageFilterAndUI(msgFromServer, cli)

asyncCheck checkServers()

#Checks if the clients have anything to send to their servers
proc checkBuffers() {.async.} =
    while true:
        for c in clients:
            var msgForServer = await c.csock.recvLine()
            if not (msgForServer.len == 0):
                c.outstream.writeLine(msgForServer)

asyncCheck checkBuffers()

#Continuously runs the send procs
proc middleManProc() {.async.} =
    while true:
        await sendOutLines()
        await sendInLines()
        sleep(200)

asyncCheck middleManProc()
runForever()