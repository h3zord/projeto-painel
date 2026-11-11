import Foundation

/// Emulador mínimo de grade de terminal para TUIs que redesenham no mesmo lugar (como `agy /quota`).
nonisolated enum TerminalScreen {
  static func render(_ data: Data, columns: Int, rows: Int) -> String {
    guard columns > 0, rows > 0 else { return "" }

    let blank = [Character](repeating: " ", count: columns)
    var grid = Array(repeating: blank, count: rows)
    var row = 0
    var column = 0

    let scalars = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
    var index = 0

    func lineFeed() {
      if row == rows - 1 {
        grid.removeFirst()
        grid.append(blank)
      } else {
        row += 1
      }
    }

    func erase(row target: Int, from start: Int, to end: Int) {
      guard start < end else { return }
      for cell in start..<end {
        grid[target][cell] = " "
      }
    }

    while index < scalars.count {
      let scalar = scalars[index]

      switch scalar {
      case "\u{1b}":
        index += 1
        guard index < scalars.count else { break }
        let kind = scalars[index]

        if kind == "[" {
          var parameters = ""
          index += 1
          while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
            parameters.unicodeScalars.append(scalars[index])
            index += 1
          }
          guard index < scalars.count else { break }

          let finalByte = scalars[index]
          let isPrivate = parameters.first.map { "?<>=".contains($0) } ?? false
          let numbers =
            parameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "?<>="))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
          let firstNumber = numbers.first.flatMap { $0 }
          let count = max(firstNumber ?? 1, 1)

          if isPrivate {
            if finalByte == "h" || finalByte == "l", parameters.contains("1049") {
              grid = Array(repeating: blank, count: rows)
              row = 0
              column = 0
            }
            break
          }

          switch finalByte {
          case "A":
            row = max(row - count, 0)
          case "B":
            row = min(row + count, rows - 1)
          case "C":
            column = min(column + count, columns - 1)
          case "D":
            column = max(column - count, 0)
          case "G":
            column = min(count - 1, columns - 1)
          case "H", "f":
            row = min(count - 1, rows - 1)
            let target = numbers.count > 1 ? (numbers[1] ?? 1) : 1
            column = min(max(target, 1) - 1, columns - 1)
          case "K":
            switch firstNumber ?? 0 {
            case 0:
              erase(row: row, from: column, to: columns)
            case 1:
              erase(row: row, from: 0, to: min(column + 1, columns))
            default:
              erase(row: row, from: 0, to: columns)
            }
          case "J":
            switch firstNumber ?? 0 {
            case 0:
              erase(row: row, from: column, to: columns)
              for target in (row + 1)..<rows { grid[target] = blank }
            case 1:
              for target in 0..<row { grid[target] = blank }
              erase(row: row, from: 0, to: min(column + 1, columns))
            default:
              grid = Array(repeating: blank, count: rows)
            }
          default:
            break
          }
        } else if kind == "]" || kind == "P" || kind == "_" {
          index += 1
          while index < scalars.count {
            if scalars[index] == "\u{07}" { break }
            if scalars[index] == "\u{1b}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
              index += 1
              break
            }
            index += 1
          }
        } else if kind == "(" || kind == ")" {
          index += 1
        }

      case "\r":
        column = 0
      case "\n":
        lineFeed()
      case "\u{08}":
        column = max(column - 1, 0)
      case "\t":
        column = min((column / 8 + 1) * 8, columns - 1)
      default:
        guard scalar.value >= 0x20, scalar.value != 0x7F else { break }
        if column >= columns {
          column = 0
          lineFeed()
        }
        grid[row][column] = Character(scalar)
        column += 1
      }

      index += 1
    }

    return
      grid
      .map { line in
        var text = String(line)
        while text.last == " " {
          text.removeLast()
        }
        return text
      }
      .joined(separator: "\n")
  }
}
