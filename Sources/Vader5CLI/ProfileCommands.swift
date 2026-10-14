import Foundation
import Vader5Core

func runProfileCommands(_ arguments: [String]) -> Int32? {
    guard let command = arguments.dropFirst().first,
          ["--devices", "--profile-read", "--profile-map", "--profile-name", "--profile-restore", "--help"].contains(command) else { return nil }
    do {
        if command == "--devices" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(Vader5DeviceProbe.enumerate()), as: UTF8.self))
            return 0
        }
        if command == "--help" {
            print("""
            ControlLab
              --devices                           List USB interfaces and report sizes (read-only)
              --profile-read FILE                 Read active profile to JSON backup
              --profile-map SOURCE DEST [--save]   Map numeric button IDs (e.g. 18 4 = M1 to A)
              --profile-name NAME [--save]         Rename active profile (10 UTF-16 units)
              --profile-restore FILE [--save]      Restore backup on the same controller/slot
              --firmware                          Read installed firmware versions
              --controller-lighting-config        Read controller lighting
              --dock-status                       Check charging dock

            Without --save profile edits apply in RAM. Every write creates a backup.
            Close the GUI before using the CLI. Use the GUI Firmware page for updates.
            Button IDs: Up=0 Right=1 Down=2 Left=3 A=4 B=5 View=6 X=7 Y=8 Menu=9
                        LB=10 RB=11 LT=12 RT=13 L3=14 R3=15 C=16 Z=17 M1..M4=18..21
            """)
            return 0
        }
        let args = Array(arguments.dropFirst(2))
        let persist = args.last == "--save"
        let values = persist ? Array(args.dropLast()) : args
        let expected = command == "--profile-map" ? 2 : 1
        guard values.count == expected, !(command == "--profile-read" && persist) else {
            throw ControllerProtocolError.invalid("Invalid arguments. Run --help.")
        }
        let current = try Vader5Profiles.readActive()
        if command == "--profile-read" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(current).write(to: URL(fileURLWithPath: values[0]), options: .atomic)
            print("Exported profile \(current.slot + 1) for device \(current.identity.deviceID).")
            return 0
        }
        var profile = try current.profile()
        switch command {
        case "--profile-map":
            guard let source = Int(values[0]), let destination = Int(values[1]) else {
                throw ControllerProtocolError.invalid("Button IDs must be numbers. Run --help.")
            }
            try profile.map(source, to: destination)
        case "--profile-name": try profile.setTitle(values[0])
        case "--profile-restore":
            let backup = try JSONDecoder().decode(ControllerProfileSnapshot.self,
                from: Data(contentsOf: URL(fileURLWithPath: values[0])))
            guard backup.identity == current.identity, backup.slot == current.slot else {
                throw ControllerProtocolError.conflict
            }
            profile = try profile.restoringContents(from: backup.profile())
        default: break
        }
        let backup = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vader5-before-write-\(UUID().uuidString).json")
        print("Backup: \(backup.path)")
        _ = try Vader5Profiles.apply(profile, replacing: current, persist: persist, backupURL: backup)
        print(persist ? "Saved to controller; readback verified." : "Applied in RAM; readback verified. Not saved across restart.")
        return 0
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        return 1
    }
}
