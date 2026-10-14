import Darwin
import Foundation

enum Key: Equatable {
    case character(Character)
    case control(UInt8)
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
    case escape
    case backspace
    case enter
}

struct TerminalSize: Equatable {
    var columns: Int
    var rows: Int
}

nonisolated(unsafe) private var savedTermios = termios()
nonisolated(unsafe) private var rawModeActive = false

private let restoreHandler: @convention(c) (Int32) -> Void = { signalNumber in
    if rawModeActive {
        var termios = savedTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios)
        let restore = Array("\u{1b}[0m\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l".utf8)
        restore.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
    }
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

final class Terminal {
    private var pending: [UInt8] = []
    private(set) var size = TerminalSize(columns: 80, rows: 24)

    func enter() {
        var termios = termios()
        tcgetattr(STDIN_FILENO, &termios)
        savedTermios = termios
        var raw = termios
        cfmakeraw(&raw)
        withUnsafeMutableBytes(of: &raw.c_cc) { buffer in
            if buffer.count > 17 {
                buffer[16] = 0
                buffer[17] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawModeActive = true
        signal(SIGWINCH, SIG_IGN)
        signal(SIGINT, restoreHandler)
        signal(SIGTERM, restoreHandler)
        signal(SIGHUP, restoreHandler)
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?7l\u{1b}[2J\u{1b}[H")
        size = Self.readSize()
    }

    func leave() {
        write("\u{1b}[0m\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l")
        if rawModeActive {
            var termios = savedTermios
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios)
            rawModeActive = false
        }
    }

    func refreshSize() -> Bool {
        let next = Self.readSize()
        let changed = next != size
        size = next
        return changed
    }

    func poll(timeoutMilliseconds: Int) -> [Key] {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&descriptor, 1, Int32(timeoutMilliseconds))
        if result > 0 {
            var buffer = [UInt8](repeating: 0, count: 128)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                pending.append(contentsOf: buffer.prefix(count))
                if count < buffer.count { break }
            }
        }
        return parsePending()
    }

    func write(_ text: String) {
        text.withCString { pointer in
            var remaining = strlen(pointer)
            var cursor = UnsafeRawPointer(pointer)
            while remaining > 0 {
                let wrote = Darwin.write(STDOUT_FILENO, cursor, remaining)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= wrote
                cursor = cursor.advanced(by: wrote)
            }
        }
    }

    private func parsePending() -> [Key] {
        var keys: [Key] = []
        var index = 0
        while index < pending.count {
            let byte = pending[index]
            if byte == 0x1b {
                guard index + 1 < pending.count else { break }
                let next = pending[index + 1]
                if next == 0x5b || next == 0x4f {
                    guard index + 2 < pending.count else { break }
                    let code = pending[index + 2]
                    switch code {
                    case 0x41:
                        keys.append(.up)
                        index += 3
                    case 0x42:
                        keys.append(.down)
                        index += 3
                    case 0x43:
                        keys.append(.right)
                        index += 3
                    case 0x44:
                        keys.append(.left)
                        index += 3
                    case 0x48:
                        keys.append(.home)
                        index += 3
                    case 0x46:
                        keys.append(.end)
                        index += 3
                    case 0x35, 0x36:
                        guard index + 3 < pending.count else { break }
                        if pending[index + 3] == 0x7e {
                            keys.append(code == 0x35 ? .pageUp : .pageDown)
                            index += 4
                        } else {
                            index += 1
                        }
                    default:
                        if index + 3 < pending.count, pending[index + 3] == 0x7e {
                            index += 4
                        } else {
                            index += 3
                        }
                    }
                } else {
                    keys.append(.escape)
                    index += 1
                }
            } else if byte == 127 || byte == 8 {
                keys.append(.backspace)
                index += 1
            } else if byte == 13 || byte == 10 {
                keys.append(.enter)
                index += 1
            } else if byte < 32 {
                keys.append(.control(byte))
                index += 1
            } else if let scalar = UnicodeScalar(UInt32(byte)) {
                keys.append(.character(Character(scalar)))
                index += 1
            } else {
                index += 1
            }
        }
        if index > 0 {
            pending.removeFirst(index)
        }
        return keys
    }

    private static func readSize() -> TerminalSize {
        var window = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 {
            return TerminalSize(columns: Int(window.ws_col), rows: Int(window.ws_row))
        }
        return TerminalSize(columns: 80, rows: 24)
    }
}
