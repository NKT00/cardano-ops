#!/usr/bin/env bash
# shellcheck disable=2086,2119

genesisjq()
{
        local q=$1; shift
        jq "$q" ./keys/genesis-meta.json "$@"
}

profile_genesis_future_offset() {
        local profile=$1

        echo -n "$(profjq "$profile" .genesis.genesis_future_offset)"
}

profile_genesis() {
        local profile=$1 genesis_dir=${2:-./keys} genesis_future_offset hash non_reuse_reasons=()

        if test -z "$reuse_genesis$(profgenjq "$profile" .reuse)"
        then non_reuse_reasons+=('reuse_not_requested'); fi
        if test ! -f "$genesis_dir"/genesis.json
        then non_reuse_reasons+=('no_genesis_to_reuse'); fi

        if test ${#non_reuse_reasons[*]} -eq 0
        then local genesis_profile_mismatch
             genesis_profile_mismatch=$(genesis_profile_mismatches "$profile" "$genesis_dir")
             if test -n "$genesis_profile_mismatch"
             then non_reuse_reasons+=('profile_mismatch:'"$genesis_profile_mismatch"); fi; fi

        if test ${#non_reuse_reasons[*]} -gt 0
        then oprint "regenerating genesis from scratch -- no reuse because:  ${non_reuse_reasons[*]}"
             time profile_genesis_"$(get_era)" "$profile" "$genesis_dir"
        elif test -n "$reuse_genesis"
        then oprint "updating genesis (--reuse-genesis)"
        elif test -n "$(profgenjq "$profile" .reuse)"
        then oprint "updating genesis (.reuse in genesis profile)"
        fi
        genesis_future_offset=$(profile_genesis_future_offset "$profile")
        start_timestamp=$(date +%s --date="now + ${genesis_future_offset}")

        genesis_update_starttime "$start_timestamp" "$genesis_dir"

        hash=$(genesis_hash "$genesis_dir")
        echo -n "$hash"> "$genesis_dir"/GENHASH

        profgenjq "$profile" . | jq > "$genesis_dir"/genesis-meta.json "
          { profile:    \"$profile\"
          , hash:       \"$hash\"
          , start_time: $start_timestamp
          , params:     ($(profgenjq "$profile" .))
          }"

        start_time=$(date --iso-8601=s --date=@$start_timestamp --utc | cut -c-19)
        oprint "genesis start time:  $start_time, $genesis_future_offset from now"
}

genesis_hash() {
        genesis_hash_"$(get_era)" "$@"
}

genesis_starttime() {
        genesis_starttime_"$(get_era)" "$@"
}

genesis_profile_mismatches() {
        genesis_profile_mismatches_"$(get_era)" "$@"
}

genesis_info() {
        genesis_info_"$(get_era)" "$@"
}

genesis_update_starttime() {
        local start_timestamp=$1 genesis_dir=$2 start_timestamp start_time

        genesis_update_starttime_"$(get_era)" "$start_timestamp" "$genesis_dir"
}

profile_shelley_genesis_protocol_params() {
        local prof=$1 composition=$2
        jq --argjson prof "$(profgenjq "${prof}" .)" \
           --argjson comp "$composition" '
          include "profile-genesis" { search: "bench" };

          . * shelley_genesis_protocol_params($prof; $comp)
        '
}

profile_shelley_genesis_cli_args() {
        local prof=$1 composition=$2 cmd=$3
        jq --argjson prof        "$(profgenjq "${prof}" .)" \
           --argjson composition "$composition" \
           --arg     cmd         "$cmd" '
          include "profile-genesis" { search: "bench" };

          shelley_genesis_cli_args($prof; $composition; $cmd)
          | join(" ")
        ' --null-input --raw-output
}

__KEY_ROOT=
key_depl() {
        local type=$1 kind=$2 id=$3
        case "$kind" in
                bulk )     suffix='.creds';;
                cert )     suffix='.cert';;
                count )    suffix='.counter';;
                none )     suffix='';;
                sig )      suffix='.skey';;
                ver )      suffix='.vkey';;
                * )        fail "key_depl: unknown key kind: '$kind'";; esac
        case "$type" in
                bulk )     stem=node-keys/bulk${id};;
                cold )     stem=node-keys/cold/operator${id};;
                opcert )   stem=node-keys/node${id}.opcert;;
                KES )      stem=node-keys/node-kes${id};;
                VRF )      stem=node-keys/node-vrf${id};;
                * )        fail "key_depl: unknown key type: '$type'";; esac
        echo "$__KEY_ROOT"/${stem}${suffix}
}
key_genesis() {
        local type=$1 kind=$2 id=$3
        case "$kind" in
                bulk )     suffix='.creds';;
                cert )     suffix='.cert';;
                count )    suffix='.counter';;
                none )     suffix='';;
                sig )      suffix='.skey';;
                ver )      suffix='.vkey';;
                * )        fail "key_genesis: unknown key kind: '$kind'";; esac
        case "$type" in
                bulk )     stem=pools/bulk${id};;
                cold )     stem=pools/cold${id};;
                opcert )   stem=pools/opcert${id};;
                KES )      stem=pools/kes${id};;
                VRF )      stem=pools/vrf${id};;
                deleg )    stem=delegate-keys/delegate${id};;
                delegCert )stem=delegate-keys/opcert${id};;
                delegKES ) stem=delegate-keys/delegate${id}.kes;;
                delegVRF ) stem=delegate-keys/delegate${id}.vrf;;
                * )        fail "key_genesis: unknown key type: '$type'";; esac
        echo "$__KEY_ROOT"/${stem}${suffix}
}

keypair_args() {
        local type=$1 id=$2 cliargprefix=${3:-}
        args=(--"${cliargprefix}"verification-key-file "$(key_depl "$type" ver "$id")"
              --"${cliargprefix}"signing-key-file      "$(key_depl "$type" sig "$id")"
             )
        if test "$type" = 'cold'
        then args+=(--operational-certificate-issue-counter-file
                    "$(key_depl cold count "$id")"); fi
        echo ${args[*]}
}

cli() {
        echo "---)  cardano-cli $*" >&2
        cardano-cli "$@" || fail "cli invocation failed"
}

profile_genesis_shelley_singleshot() {
        set -euo pipefail

        local prof="${1:-default}"
        local target_dir="${2:-./keys}"
        prof=$(params resolve-profile "$prof")

        local ids_pool_map ids
        id_pool_map_composition ""

        local topofile
        topofile=$(get_topology_file)
        oprint "genesis: topology:  $topofile"

        ids_pool_map=$(topology_id_pool_density_map "$topofile")
        oprint "genesis: id-pool map:  $ids_pool_map"
        if jqtest 'to_entries | map (select (.value)) | length == 0' <<<$ids_pool_map
        then fail "no pools in topology -- at least one entry must be have:  pools = <NON-ZERO>"
        fi

        ids=($(jq 'keys
                  | join(" ")
                  ' -cr <<<$ids_pool_map))

        local composition
        composition=$(id_pool_map_composition "$ids_pool_map")
        oprint "genesis: id-pool map composition:  $composition"

        mkdir -p "$target_dir"
        rm -rf -- ./"$target_dir"
        __KEY_ROOT="$target_dir"

        params=(--genesis-dir      "$target_dir"
                --gen-utxo-keys    1
                $(profile_shelley_genesis_cli_args "$prof" "$composition" 'create0'))
        cli genesis create "${params[@]}"

        ## set parameters in template
        profile_shelley_genesis_protocol_params "$prof" "$composition" \
         < "$target_dir"/genesis.spec.json > "$target_dir"/genesis.spec.json.
        mv "$target_dir"/genesis.spec.json.  "$target_dir"/genesis.spec.json

        params=(--genesis-dir      "$target_dir"
                $(profile_shelley_genesis_cli_args "$prof" "$composition" 'create1')
               )
        ## update genesis from template
        cli genesis create-staked "${params[@]}"

        genesis_shelley_copy_keys "$prof" "$ids_pool_map"

        ## Fix up the key, so the generator can read it:
        sed -i 's_PaymentSigningKeyShelley_SigningKeyShelley_' "$target_dir"/utxo-keys/utxo1.skey
}

genesis_shelley_copy_keys() {
        local profile=$1 ids_pool_map=$2
        local ids ids_pool

        set -e

        ids=($(jq 'keys
                  | join(" ")
                  ' -cr <<<$ids_pool_map))
        local bid=1 pid=1 did=1 ## (B)FT, (P)ool, (D)ense pool
        for id in ${ids[*]}
        do
            mkdir -p "$target_dir"/node-keys/cold

            #### cold keys (do not copy to production system)
            if   jqtest ".dense_pool_density > 1" <<<$(profgenjq "$profile" .) &&
                 jqtest ".[\"$id\"]  > 1" <<<$ids_pool_map
            then ## Dense/bulk pool
               oprint "genesis:  bulk pool $did -> node-$id"
               cp -f $(key_genesis bulk      bulk $did) $(key_depl bulk   bulk $id)
               did=$((did + 1))
            elif jqtest ".[\"$id\"] != 0" <<<$ids_pool_map
            then ## Singular pool
               oprint "genesis:  pool $pid -> node-$id"
               cp -f $(key_genesis cold       sig $pid) $(key_depl cold    sig $id)
               cp -f $(key_genesis cold       ver $pid) $(key_depl cold    ver $id)
               cp -f $(key_genesis opcert    cert $pid) $(key_depl opcert none $id)
               cp -f $(key_genesis opcert   count $pid) $(key_depl cold  count $id)
               cp -f $(key_genesis KES        sig $pid) $(key_depl KES     sig $id)
               cp -f $(key_genesis KES        ver $pid) $(key_depl KES     ver $id)
               cp -f $(key_genesis VRF        sig $pid) $(key_depl VRF     sig $id)
               cp -f $(key_genesis VRF        ver $pid) $(key_depl VRF     ver $id)
               pid=$((pid + 1))
            else ## BFT node
               oprint "genesis:  BFT $bid -> node-$id"
               cp -f $(key_genesis deleg      sig $bid) $(key_depl cold    sig $id)
               cp -f $(key_genesis deleg      ver $bid) $(key_depl cold    ver $id)
               cp -f $(key_genesis delegCert cert $bid) $(key_depl opcert none $id)
               cp -f $(key_genesis deleg    count $bid) $(key_depl cold  count $id)
               cp -f $(key_genesis delegKES   sig $bid) $(key_depl KES     sig $id)
               cp -f $(key_genesis delegKES   ver $bid) $(key_depl KES     ver $id)
               cp -f $(key_genesis delegVRF   sig $bid) $(key_depl VRF     sig $id)
               cp -f $(key_genesis delegVRF   ver $bid) $(key_depl VRF     ver $id)
               bid=$((bid + 1))
            fi
        done
}

profile_genesis_shelley() {
        profile_genesis_shelley_singleshot "$@"
}

genesis_starttime_shelley() {
        local genesis_dir=${1:-./keys}
        date --date=$(jq '.systemStart' "$genesis_dir"/genesis.json |
                      tr -d '"Z') +%s
}

genesis_info_shelley() {
        local genesis_dir=${1:-./keys}
        local g=$genesis_dir/genesis.json

        local genesis_delegation_map_size genesis_n_delegator_keys genesis_n_bulk_creds
        genesis_delegation_map_size=$(\
            jq '.staking.stake | keys | length' $g)
        genesis_n_delegator_keys=$(($(\
            ls $genesis_dir/stake-delegator-keys | wc -l) / 2))
        genesis_utxo_size=$(\
            jq '.initialFunds | keys | length' $g)
        genesis_n_bulk_creds=$(\
            ls $genesis_dir/pools/bulk*.creds | wc -l)

        cat <<EOF
--( Genesis in $genesis_dir:
----|  delegation map size:             $genesis_delegation_map_size
----|  delegator key count:             $genesis_n_delegator_keys
----|  genesis UTxO size:               $genesis_utxo_size
----|  bulk credential files:           $genesis_n_bulk_creds
----|  bulk credential file cred count:
EOF
        local n=0 actual
        echo -ne '\b'
        for bulkf in $genesis_dir/pools/bulk*.creds
        do echo -n " $n:$(jq length $bulkf)"
           n=$((n+1))
        done
        echo
}

genesis_profile_mismatches_shelley() {
        local profile=$1 genesis_dir=${2:-./keys}
        local g=$genesis_dir/genesis.json

        local genesis_delegation_map_size genesis_n_delegator_keys genesis_n_bulk_creds
        genesis_delegation_map_size=$(\
            jq '.staking.stake | keys | length' $g)
        genesis_n_delegator_keys=$(($(\
            ls $genesis_dir/stake-delegator-keys | wc -l) / 2))
        genesis_utxo_size=$(\
            jq '.initialFunds | keys | length' $g)
        genesis_n_bulk_creds=$(\
            ls $genesis_dir/pools/bulk*.creds 2>/dev/null | wc -l)

        local topofile ids_pool_map composition
        topofile=$(get_topology_file)
        ids_pool_map=$(topology_id_pool_density_map "$topofile")
        composition=$(id_pool_map_composition "$ids_pool_map")

        local prof_n_extra_delegs prof_pool_density prof_n_dense_hosts prof_n_dense_pools
        prof_n_extra_delegs=$(profgenjq "$profile" .extra_delegators)
        prof_pool_density=$(profgenjq "$profile" .dense_pool_density)
        prof_n_dense_hosts=$(($(jq .n_dense_hosts <<<$composition)))
        prof_n_sing_hosts=$(($(jq .n_singular_hosts <<<$composition)))
        prof_n_dense_pools=$((prof_pool_density * prof_n_dense_hosts))
        prof_stuffed_utxo=$(profgenjq "$profile" .stuffed_utxo)
        prof_expected_utxo=$((prof_stuffed_utxo + prof_n_extra_delegs + prof_n_sing_hosts))

        if test "$genesis_delegation_map_size" -ne "$prof_n_extra_delegs"
        then echo -n "genesis-delegation-map-size-${genesis_delegation_map_size}-not-equal-to-profile-extra-delegs-${prof_n_extra_delegs} "; fi

        if test "$genesis_n_delegator_keys" -lt "$prof_n_extra_delegs"
        then echo -n "genesis-delegator-key-${genesis_n_delegator_keys}-count-less-than-profile-extra-delegs-${prof_n_extra_delegs} "; fi

        if test "$genesis_n_bulk_creds" -lt "$prof_n_dense_hosts"
        then echo -n "genesis-bulk-cred-file-count-${genesis_n_bulk_creds}-less-than-profile-pools-count-${prof_n_dense_hosts} "; fi

        if test "$genesis_utxo_size" -ne "$prof_expected_utxo"
        then echo -n "genesis-utxo-${genesis_utxo_size}-less-than-profile-${prof_expected_utxo} "; fi

        local n=0 actual
        for bulkf in $(ls $genesis_dir/pools/bulk*.creds 2>/dev/null)
        do actual=$(jq length $bulkf 2>/dev/null || echo 0)
           if test "$actual" -lt $prof_pool_density
           then echo -n " bulk-file-${n}-pools-${actual}-below-profile-pool-density-${prof_pool_density}"; fi
           n=$((n+1))
        done
}

genesis_update_starttime_shelley() {
        local start_timestamp=$1 genesis_dir=${2:-./keys} start_time

        start_time=$(date --iso-8601=s --date=@$start_timestamp --utc | cut -c-19)
        json_file_append "$genesis_dir"/genesis.json "
          { systemStart: \"${start_time}Z\" }" <<<0
}

genesis_hash_shelley() {
        local genesis_dir="${1:-./keys}"

        cardano-cli genesis hash --genesis "${genesis_dir}"/genesis.json |
                tr -d '"'
}
