import Foundation

enum CasosQueDevemReprovar {
  static func exemplos(valor: Int?) throws {
    let r = try! NSRegularExpression(pattern: "a") // reprova
    let v = valor! // reprova
    var implicito: String! // reprova
    do { try algo() } catch {} // reprova
    do { try algo() } catch let erro { /* engolido */ } // reprova
    let agora1 = Date() // reprova
    let agora2 = Date.now // reprova
    let agora3: Date = .now // reprova
    let env1 = ProcessInfo.processInfo.environment["HOME"] // reprova
    let env2 = getenv("PATH") // reprova
    _ = (r, v, implicito, agora1, agora2, agora3, env1, env2)
  }

  static func algo() throws {}
}
