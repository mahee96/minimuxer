import PackagePlugin
import Foundation

@main
struct RustBuildPlugin: BuildToolPlugin {

    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {

        let rustDir = context.package.directory
            .appending("RustBridge")

        let cargoTarget =
            context.pluginWorkDirectory.appending("cargo")

        let triples = [
            "aarch64-apple-ios",
            "aarch64-apple-ios-sim"
        ]

        return triples.map { triple in
            let outputLib = cargoTarget
                .appending(triple)
                .appending("debug")
                .appending("librust_bridge-\(triple).a")

            let script = """
            set -e

            echo "=============================="
            echo " SwiftPM Rust Build Plugin"
            echo " Building: \(triple)"
            echo "=============================="

            if [ -f "\(outputLib.string)" ]; then
                echo "Already built → skipping"
                exit 0
            fi

            cd "\(rustDir.string)"

            export CARGO_TARGET_DIR="\(cargoTarget.string)"
            export CARGO_TERM_COLOR=always

            CARGO_BIN="$HOME/.cargo/bin/cargo"

            if [ ! -x "$CARGO_BIN" ]; then
                echo "cargo not found at $CARGO_BIN"
                exit 1
            fi

            echo "Using cargo: $CARGO_BIN"

            "$CARGO_BIN" build --target \(triple) 2>&1 | cat

            # rename so SPM outputs are unique
            cp \
              "\(cargoTarget.string)/\(triple)/debug/librust_bridge.a" \
              "\(outputLib.string)"
            """

            return .buildCommand(
                displayName: "Rust bridge → \(triple)",
                executable: .init("/usr/bin/env"),
                arguments: ["sh", "-c", script],
                inputFiles: [],
                outputFiles: [outputLib]
            )
        }
    }
}
