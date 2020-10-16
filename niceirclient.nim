import streams, os, asyncnet, asyncdispatch, net, strutils, terminal

#This file is currently a dummy tester

type
    ClientInfoHere = object
        descriptor, channel, username, nick: string
        sock: AsyncSocket
        incoming, outgoing: StringStream

var statusline: string = ""

var this: ClientInfoHere
this.incoming = newStringStream("")
this.outgoing = newStringStream("")

var linepersist: string = newString(400)

proc readFromDae() {.async.} =
    while true:
        sleep(200)
        this.incoming.writeLine(await this.sock.recvLine())

proc readToDae() {.async.} = 
    while true:
        sleep(200)
        while not this.outgoing.atEnd():
            await this.sock.send(this.outgoing.readLine())
        this.outgoing.flush()


proc restoreUserline() =
    eraseLine()
    write(stdout, "<" & this.nick & ">" & linepersist)

proc readFromInput() {.async.} =
    discard readLine(stdin, linepersist)
    if not linepersist.startsWith("/"):
        this.outgoing.writeLine("PRIVMSG " & this.channel & " :" & linepersist)
        linepersist = newString(400)
    else:
        linepersist.removePrefix("/")
        if linepersist.startsWith("NICK "): this.nick = linepersist.splitWhitespace()[1]
        this.outgoing.writeLine(linepersist)
        linepersist = newString(400)

proc updateBuffer() {.async.} =
    while not this.incoming.atEnd():
        eraseLine()
        write(stdout, this.incoming.readLine() & "\n")
    restoreUserline()
    asyncCheck readFromInput()
    return

proc prodServer() {.async.} =
    var tempsock: AsyncSocket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    await tempsock.connectUnix(getHomeDir() & "/.nicesockMAST")
    var cmdline = commandLineParams()
    if cmdline.len == 0:
        echo "please enter the command with [servcfgfile] [channel] [internalname] [clientnick]"
        quit(21)
    var toMast = "NEW " & cmdline.join(" ") & "\n"
    await tempsock.send(toMast)
    this.descriptor = cmdline[2]
    this.channel = cmdline[1]
    #this upcoming line is a testing hack i really dont want to implement this properly right now
    this.nick = cmdline[3]

waitFor prodServer()
sleep(1000)
this.sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
waitFor connectUnix(this.sock, getHomeDir() & "/.nicesock-" & this.descriptor)

asyncCheck readFromDae()
asyncCheck readToDae()

var shouldQuit: bool = false

asyncCheck updateBuffer()
runForever()