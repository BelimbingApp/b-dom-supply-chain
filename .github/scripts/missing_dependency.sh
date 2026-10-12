#!/usr/bin/env bash
# Proves a missing Supply Chain dependency fails composition.
#
# Run from a Bilimbi root with Supply Chain mounted at apps/domains/supply_chain and the
# workspace already compiled. The script mounts a throwaway Extension whose one
# module depends on supply_chain/purchasing, moves Supply Chain out of apps/, and requires
# discovery to refuse the graph with the missing-dependency error. It then
# remounts Supply Chain and requires the same graph to compile. The fixture is
# written here and removed on exit; it is never a real Extension.
set -euo pipefail

root=$(pwd -P)
supply_chain="$root/apps/domains/supply_chain"
parked="$root/.scratchpad/supply-chain-parked"
fixture="$root/apps/extensions/supply_chain_probe"
expected="module supply_chain_probe/probe declares missing dependency supply_chain/purchasing"

[ -f "$root/apps/domains/AGENTS.md" ] || { echo "run from a Bilimbi root" >&2; exit 2; }
[ -d "$supply_chain" ] || { echo "Supply Chain is not mounted at $supply_chain" >&2; exit 2; }
[ ! -e "$fixture" ] || { echo "$fixture already exists" >&2; exit 2; }
[ ! -e "$parked" ] || { echo "$parked already exists" >&2; exit 2; }

build="$root/_build/${MIX_ENV:-dev}/lib"

restore() {
  if [ -d "$parked" ] && [ ! -e "$supply_chain" ]; then mv "$parked" "$supply_chain"; fi
  rm -rf "$fixture" "$build/supply_chain_probe" "$build/bilimbi_supply_chain_probe_probe"
}
trap restore EXIT

mkdir -p "$fixture/probe/lib"

cat > "$fixture/bilimbi.container.exs" <<'EOF'
[id: "supply_chain_probe", kind: :container, layer: :extension]
EOF

cat > "$fixture/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.SupplyChainProbe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../..", __DIR__)

  def project do
    [
      app: :supply_chain_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.container_dependencies(__DIR__)
    ]
  end
end
EOF

cat > "$fixture/probe/bilimbi.module.exs" <<'EOF'
[
  id: "supply_chain_probe/probe",
  kind: :module,
  layer: :extension,
  required: false,
  otp_app: :bilimbi_supply_chain_probe_probe,
  namespace: Bilimbi.SupplyChainProbe.Probe,
  dependencies: ["supply_chain/purchasing"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
EOF

cat > "$fixture/probe/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.SupplyChainProbe.Probe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :bilimbi_supply_chain_probe_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.module_dependencies(__DIR__)
    ]
  end

  def application do
    [env: Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__)]
  end
end
EOF

cat > "$fixture/probe/lib/probe.ex" <<'EOF'
defmodule Bilimbi.SupplyChainProbe.Probe do
  @moduledoc false

  def purchasing, do: Bilimbi.SupplyChain.Purchasing
end
EOF

# Supply Chain absent while a mounted dependent requires it: composition refuses.
mv "$supply_chain" "$parked"
set +e
output=$(mix compile 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "$output"
  echo "composition accepted supply_chain_probe/probe without Supply Chain mounted" >&2
  exit 1
fi

if ! grep -qF "$expected" <<<"$output"; then
  echo "$output"
  echo "composition failed without the expected error: $expected" >&2
  exit 1
fi

echo "without Supply Chain: $expected"

# Supply Chain mounted again: the same graph composes and compiles.
mv "$parked" "$supply_chain"
mix compile

if [ ! -f "$build/bilimbi_supply_chain_probe_probe/ebin/Elixir.Bilimbi.SupplyChainProbe.Probe.beam" ]; then
  echo "supply_chain_probe/probe did not compile with Supply Chain mounted" >&2
  exit 1
fi

echo "with Supply Chain: supply_chain_probe/probe composes and compiles"
