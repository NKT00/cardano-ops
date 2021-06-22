# Topology file for a simple testnet consisting of BFT nodes and stakepool nodes.
#
# See attributes `bftNodeRegionNames` and `poolRegionNames` to understand how
# to customize the number of nodes in the network, and the regions in which
# they are deployed.
#
# * Debugging the topology
#
# You can use `nix eval` to query the different attributes of the topology and
# check that their values match your expectations.
#
# > nix eval '(with import ./nix {}; with lib;  map (x: x.name) globals.topology.coreNodes)'
#
pkgs: with pkgs; with lib; with topology-lib;
let
  regions = {
    a = { name = "eu-central-1";   /* Europe (Frankfurt)       */ };
    b = { name = "us-east-2";      /* US East (Ohio)           */ };
    c = { name = "ap-southeast-1"; /* Asia Pacific (Singapore) */ };
    d = { name = "eu-west-2";      /* Europe (London)          */ };
    e = { name = "eu-central-1";   /* Europe (Frankfurt)       */ };
    f = { name = "us-east-2";      /* US East (Ohio)           */ };
    g = { name = "ap-southeast-1"; /* Asia Pacific (Singapore) */ };
    h = { name = "eu-west-2";      /* Europe (London)          */ };
    i = { name = "ap-southeast-1"; /* Asia Pacific (Singapore) */ };
    j = { name = "eu-west-2";      /* Europe (London)          */ };
    k = { name = "eu-central-1";   /* Europe (Frankfurt)       */ };
  };

  bftCoreNodes =
    let
      # The region names will determine the number of BFT nodes. These names
      # should belong to `attrNames regions`.
      bftNodeRegionNames = [ "a" ];
      # BFT node specifications, which will be used to create BFT nodes.
      bftNodeSpecs =
        genList
        (i: { region = builtins.elemAt bftNodeRegionNames i;
              org    = "IOHK";
              nodeId = i + 1;
            }
        )
        (length bftNodeRegionNames);
      mkBftCoreNode = mkBftCoreNodeForRegions regions;
      bftNodes =
        map defineKeys
            (fullyConnectNodes
              (map ({ region, org, nodeId}: mkBftCoreNode region 1 { inherit org nodeId;})
                   bftNodeSpecs
              ));
      defineKeys = x :
        x // {
          imports = [{
            deployment.keys = {
              "utxo.vkey" = {
                keyFile = ../keys/utxo-keys + "/utxo${toString x.nodeId}.vkey";
                destDir = "/root/keys";
              };
              "utxo.skey" = {
                keyFile = ../keys/utxo-keys + "/utxo${toString x.nodeId}.skey";
                destDir = "/root/keys";
              };
              "delegate.vkey" = {
                keyFile = ../keys/delegate-keys + "/delegate${toString x.nodeId}.vkey";
                destDir = "/root/keys";
              };
              "delegate.skey" = {
                keyFile = ../keys/delegate-keys + "/delegate${toString x.nodeId}.skey";
                destDir = "/root/keys";
              };
              "genesis.vkey" = {
                keyFile = ../keys/genesis-keys + "/genesis${toString x.nodeId}.vkey";
                destDir = "/root/keys";
              };
              "genesis.skey" = {
                keyFile = ../keys/genesis-keys + "/genesis${toString x.nodeId}.skey";
                destDir = "/root/keys";
              };
            };
          }];
        };
      in connectGroupWith (reverseList stakePoolNodes) bftNodes;

  relayNodes = [];

  stakePoolNodes =
    let
      # The region names determine the number of stake pools. These names
      # should belong to `attrNames regions`.
      poolRegionNames = [ "b" ];
      # poolRegionNames = [ "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" ];

      # Stake pool specifications, which will be used to create stake pools.
      poolSpecs =
        genList
        (i: { region   = builtins.elemAt poolRegionNames i;
              nodeName = "IOHK" + toString ((length bftCoreNodes) + i + 1);
              nodeId   = (length bftCoreNodes) + i + 1;
            }
        )
        (length poolRegionNames);
      mkStakingPool = mkStakingPoolForRegions regions;
      pools =
        map defineKeys
            (fullyConnectNodes
              (map ({ region, nodeName, nodeId}: mkStakingPool region 1 nodeName { nodeId = nodeId;})
                   poolSpecs
              ));
      # We need to have the keys available in the node to be able to perform
      # tests. This is OK for tests, but do not store keys in the node in
      # production.
      defineKeys = x :
        x // {
          imports = [{
            deployment.keys = {
              "utxo.vkey" = {
                keyFile = ../keys/utxo-keys + "/utxo${toString x.nodeId}.vkey";
                destDir = "/root/keys";
              };
              "utxo.skey" = {
                keyFile = ../keys/utxo-keys + "/utxo${toString x.nodeId}.skey";
                destDir = "/root/keys";
              };
              "cold.vkey" = {
                keyFile = ../keys/pool-keys + "/node${toString x.nodeId}-cold.vkey";
                destDir = "/root/keys";
              };
              "cold.skey" = {
                keyFile = ../keys/pool-keys + "/node${toString x.nodeId}-cold.skey";
                destDir = "/root/keys";
              };
              "node-vrf.vkey" = {
                keyFile = ../keys/node-keys + "/node-vrf${toString x.nodeId}.vkey";
                destDir = "/root/keys";
              };
              "node-vrf.skey" = {
                keyFile = ../keys/node-keys + "/node-vrf${toString x.nodeId}.skey";
                destDir = "/root/keys";
              };
            };
          }];
        };
    in
      connectGroupWith bftCoreNodes pools;

  coreNodes = bftCoreNodes ++ stakePoolNodes;
in {
  inherit bftCoreNodes stakePoolNodes coreNodes relayNodes;
}
