import Foundation
import Testing
@testable import DMMKit

@Suite struct CatalogueTests {
    @Test func loadsAndEveryPatternCompiles() {
        let catalogue = SCPICatalogue.shared
        #expect(catalogue.commands.count > 300)
        for info in catalogue.commands {
            #expect((try? NSRegularExpression(pattern: SCPICatalogue.pattern(for: info.command))) != nil, "\(info.command)")
        }
    }

    @Test(arguments: [
        ("VOLT:NPLC?", "[SENSe:]VOLTage[:DC]:NPLC"),
        (":sense:voltage:dc:nplc 10", "[SENSe:]VOLTage[:DC]:NPLC"),
        ("VOLT:AC:BAND", "[SENSe:]VOLTage:AC:BANDwidth"),
        ("FRES:RANG:AUTO ONCE", "[SENSe:]FRESistance:RANGe:AUTO"),
        ("*IDN?", "*IDN?"),
        ("R? 100", "R?"),
        ("SAMP:TIM", "SAMPle:TIMer"),
        ("SYST:ERR?", "SYSTem:ERRor[:NEXT]?"),
        ("HCOP:SDUM:DATA?", "HCOPy:SDUMp:DATA?"),
    ])
    func lookup(text: String, expected: String) {
        #expect(SCPICatalogue.shared.lookup(text)?.command == expected)
    }

    @Test func unknownHeadersAreNotMatched() {
        #expect(SCPICatalogue.shared.lookup("BOGUS:CMD?") == nil)
        #expect(SCPICatalogue.shared.lookup("VOLT:NPL") == nil)
        #expect(SCPICatalogue.shared.lookup("") == nil)
    }

    @Test func everyProfileHeaderIsDocumented() {
        for function in MeasurementFunction.allCases {
            for setting in FunctionProfile.profile(for: function).settings {
                #expect(SCPICatalogue.shared.lookup(setting.header) != nil, "\(function) \(setting.header)")
                if let auto = setting.auto {
                    #expect(SCPICatalogue.shared.lookup(auto.header) != nil, "\(function) \(auto.header)")
                }
            }
        }
    }
}
