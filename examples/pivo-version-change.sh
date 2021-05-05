#!/usr/bin/env bash
#
# This test script registers stakepools, submits an update proposal, and have
# the stake holders voting on it so that it is approved.
#
# This script requires the following environment variables to be defined:
#
# - BFT_NODES: names of the BFT nodes
# - POOL_NODES: names of the stake pool nodes
#
# Troubleshooting:
#
# This script is deployed locally and in an AWS cluster. Deploying it locally
# is relatively fast, however an AWS deployment takes several minutes. Thus,
# the network start time has to be adjusted accordingly in
# `create-shelley-genesis-and-keys`. Setting the network start time 10 minutes
# in the future is usually enough for the AWS testnet to properly start.
set -euo pipefail

[ -z ${BFT_NODES+x} ] && (echo "Environment variable BFT_NODES must be defined"; exit 1)
[ -z ${POOL_NODES+x} ] && (echo "Environment variable POOL_NODES must be defined"; exit 1)

CLI=cardano-cli

. $(dirname $0)/pivo-version-change/lib.sh

if [ -z ${1+x} ];
then
    echo "'redeploy' command was not specified, so the test will run on an existing testnet";
else
    case $1 in
        redeploy )
            echo "Redeploying the testnet"
            nixops destroy --confirm
            ./scripts/create-shelley-genesis-and-keys.sh
            nixops deploy -k
            ;;
        * )
            echo "Unknown command $1"
            exit
    esac
fi

# fixme: we might not need the BFT_NODES environment variable.
BFT_NODES=($BFT_NODES)
POOL_NODES=($POOL_NODES)

# Copy the scripts to the pool nodes
for f in ${POOL_NODES[@]}
do
    nixops scp $f examples/pivo-version-change/lib.sh /root/ --to
    nixops scp $f examples/pivo-version-change/run.sh /root/ --to
done

clear

# Register the stake pools
echo
echo "Registering stake pools"
echo
for f in ${POOL_NODES[@]}
do
    nixops ssh $f "./run.sh register" &
done
wait
# TODO: we should detect if any of the stake pool registration commands failed.
echo
echo "Stake pools registered"
echo

# You can query the blocks produced by each stakepool by running:
#
#   cardano-cli query ledger-state --testnet-magic 42 --shelley-mode | jq '.blocksCurrent'
#
################################################################################
## Submit the SIP
################################################################################
echo
echo "Submitting an SIP commit using ${POOL_NODES[0]}"
echo
nixops ssh ${POOL_NODES[0]} "./run.sh scommit"

################################################################################
## Reveal the SIP
################################################################################
# Wait till the submission is stable in the chain. This depends on the global
# parameters of the era. More specifically:
#
# - activeSlotsCoeff
# - securityParam
# - slotLength
#
# TODO: ideally the values of these parameters should be retrieved from the
# node (or at least from the environment variables provided by the nix
# infrastructure, although it is better not to rely on this since the ultimate
# source of truth should be the node). For simplicity we use the values of the
# test genesis file, however there is no sanity check that the values assumed
# in this script are correct.
#
# We assume:
#
# - activeSlotsCoeff = 0.1
# - securityParam    = 10
# - slotLength       = 0.2
#
# So we have:
#
# - stabilityWindow = (3 * securityParam) / activeSlotsCoeff = (3 * 10) / 0.1 = 300
#
# We assume (according to the values of the genesis file) that a slot occurs
# every 0.2 seconds, so we need to wait for 300 * 0.2 = 60 seconds. In practice
# we add a couple of seconds to be on the safe side. In a proper test script we
# would ask the node when a given commit is stable on the chain.
pretty_sleep 65 "Waiting for SIP submission to be stable"

echo
echo "Submitting an SIP revelation using ${POOL_NODES[0]}"
echo
nixops ssh ${POOL_NODES[0]} "./run.sh sreveal"

################################################################################
## Vote on the proposal
################################################################################
# We wait till the revelation is stable on the chain, which means that the
# voting period is open.
pretty_sleep 65 "Waiting for SIP revelation to be stable"

echo
echo "Voting on the SIP"
echo
for f in ${POOL_NODES[@]}
do
    nixops ssh $f "./run.sh svote" &
done
wait

################################################################################
## Submit an implementation commit
################################################################################
echo
echo "Submitting an implementation commit using ${POOL_NODES[0]}"
echo
nixops ssh ${POOL_NODES[0]} "./run.sh icommit"

################################################################################
## Reveal the implementation
################################################################################
# Wait till the SIP vote period ends, so that votes are tallied and the SIP is
# marked as approved.
pretty_sleep 180 "Waiting for the SIP voting period to end"

echo
echo "Submitting an implementation revelation using ${POOL_NODES[0]}"
echo
nixops ssh ${POOL_NODES[0]} "./run.sh ireveal"

################################################################################
## Vote on the implementation
################################################################################
pretty_sleep 65 "Waiting till the implementation revelation is stable"
echo
echo "Voting on the implementation"
echo
for f in ${POOL_NODES[@]}
do
    nixops ssh $f "./run.sh ivote" &
done
wait

################################################################################
## Endorse the implementation
################################################################################
# Wait till the end of the voting period is stable
pretty_sleep 180 "Waiting till the end of the voting period is stable"

echo
echo "Endorsing the proposed version"
echo
for f in ${POOL_NODES[@]}
do
    nixops ssh $f "./run.sh endorse" &
done
wait

# To query the ledger state use:
#
# cardano-cli query ledger-state --testnet-magic 42 --pivo-era --pivo-mode | jq '.stateBefore.esLState.utxoState.ppups '

# To query the protocol parameters use:
#
# cardano-cli query protocol-parameters --testnet-magic 42 --shelley-era --shelley-mode | jq .maxBlockBodySize