import Foundation

/// Converte saída bruta de terminal em texto plano preservando espaçamento horizontal.
nonisolated enum TerminalText {
  /// Movimentos horizontais de cursor viram espaços porque TUIs como o Claude Code posicionam
  /// palavras com `ESC[<coluna>G` em vez de imprimir espaços literais.
  static func clean(_ data: Data) -> String {
    let cursorMoves = #/\u{1b}\[(\d*)([CG])/#
    let controlSequences =
      #/\u{1b}\[[0-9;?<>=]*[ -/]*[@-~]|\u{1b}[\]P_][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\)|\u{1b}[()][A-Za-z0-9]|\u{1b}[=>78M]/#
    var text = String(decoding: data, as: UTF8.self)

    text = text.replacing(cursorMoves) { match in
      let count = match.output.2 == "C" ? (Int(match.output.1) ?? 1) : 1
      return String(repeating: " ", count: min(max(count, 1), 200))
    }

    text = text.replacing(controlSequences, with: "")
    return text.replacingOccurrences(of: "\r", with: "")
  }
}
