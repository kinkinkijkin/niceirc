import asyncnet, asyncdispatch, streams, os

#Configuration type, for storing configuration from a file.
type
    configServ = object
        var isCalled*, nick*, username*, realname*,
        pass*, servAddr*: string
        var servPort*: int = 6667
        var reqPass*: bool = false

#Currently connected servers and loaded configurations
var servs {.threadvar.}: seq[tuple[name: string, ssock: AsyncSocket, csock: AsyncSocket]]
var configs {.threadvar.}: seq[configServ]

#Internal buffers with sorting by type and server
var linesForClient, linesToProcIn, linesForServer, linesToProcOut:
    seq[tuple[serverName: string, linestream: StringStream]]

#Recieve messages from the server and add to processing list
proc getInFromServer(server: AsyncSocket, sname: string) {.async.} =
    while true:
        let line = await server.recvLine()
        if line.len == 0: break
        else:
            linesToProcIn.add((sname, line))

#Open communications with client UI
proc openClientUi(cui: var AsyncSocket, s: configServ, cn: string) {.async.} =
    cui = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    var sockname = ".nicesock-" & cn
    await bindUnix(cui, getHomeDir() & sockname)
    await cui.send("Client UI socket opened for " & cn & " at " & sockname)

#Open the IPC interface for clients to request new clients to be made on
proc openClientListener(clist: var AsyncSocket) {.async.} =
    clist = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_RAW)
    await bindUnix(clist, getHomeDir() & ".nicesockMAST")

#Open communications with server
proc openCommunications(server: var AsyncSocket, s: configServ, msg: var string) {.async.} =
    msg = "Connecting to " & s.isCalled
    server = await dial(s.servAddr, s.servPort.Port)
    msg = msg & "\nConnected to " & s.isCalled & " has succeeded"
    if s.reqPass:
        await server.send("PASS " & s.pass)
    msg = msg & "\nRegistering connection with nick " & s.nick
    await server.send("NICK " & s.nick)
    await server.send("USER " & s.username & " 0 * :" & s.realname)
    msg = msg & "\nPassoff from server opening proc"

var nClientListener: AsyncSocket

await openClientListener()