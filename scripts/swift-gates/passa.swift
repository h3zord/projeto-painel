import Foundation

enum CasosQueDevemPassar {
  static func exemplos(flag: Bool, a: Int, b: Int, opcional: Int?) {
    if !flag && a != b {
      let texto = "try! Date() Date.now ProcessInfo.processInfo.environment catch {}"
      let regex = #/try!|Date\(\)|!=/#
      // Comentário citando try!, valor!, Date(), Date.now e ProcessInfo.processInfo.environment
      let fixo = Date(timeIntervalSince1970: 1_762_800_000)
      let antigo = Date.distantPast
      let justificado = opcional!  // swift-gate: allow-force-unwrap invariante garantida no teste de prova
      do {
        try acao()
      } catch {
        let _ = error
      }
      _ = (texto, regex, fixo, antigo, justificado)
    }
  }

  static func acao() throws {}
}
