import streams, os, asyncnet, asyncdispatch, strutils, terminal

#This file is currently a dummy tester

type
    ClientInfoHere = object
        descriptor, channel, username, nick: string
        sock: AsyncSocket
        incoming, outgoing: StringStream

var statusline: string = ""

var this: ClientInfoHere

var linepersist: string = newString(400)

proc readFromDae() {.async.} =
    while true:
        this.incoming.writeLine(await this.sock.recvLine())

proc readToDae() {.async.} = 
    while true:
        while not this.outgoing.atEnd():
            await this.sock.send(this.outgoing.readLine())
        this.outgoing.flush()

proc restoreUserline() =
    eraseLine()
    write(stdout, "<" & this.nick & ">" & linepersist)

proc readFromInput() {.async.} =
    discard readLine(stdin, linepersist)
    this.outgoing.writeLine("PRIVMSG " & this.channel & " :" & linepersist)
    linepersist = newString(400)

proc updateBuffer() {.async.} =
    while not this.incoming.atEnd():
        eraseLine()
        write(stdout, this.incoming.readLine() & "\n")
    restoreUserline()
    asyncCheck readFromInput()
    return

proc prodServer() {.async.} =
    var tempsock: AsyncSocket
    await connectUnix(tempsock, getHomeDir() & ".nicesockMAST")
    var cmdline = commandLineParams()
    var toMast = "NEW " & cmdline.join(" ")
    await tempsock.send(toMast)
    this.descriptor = cmdline[2]
    this.channel = cmdline[1]
    #this upcoming line is a testing hack i really dont want to implement this properly right now
    this.nick = cmdline[3]

waitFor prodServer()
sleep(1000)
waitFor connectUnix(this.sock, getHomeDir() & ".nicesock-" & this.descriptor)

asyncCheck readFromDae()
asyncCheck readToDae()

var shouldQuit: bool = false

while not shouldQuit:
    waitFor updateBuffer()
    sleep(700)