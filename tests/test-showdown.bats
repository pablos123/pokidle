#!/usr/bin/env bats

load helpers

setup() {
    load_lib showdown
}

@test "showdown_format: full encounter renders correctly" {
    local enc='{
        "species":"sceptile","level":42,"nature":"adamant","ability":"overgrow",
        "is_hidden_ability":0,"gender":"M","shiny":1,"held_berry":"sitrus",
        "ivs":[31,28,19,31,24,30],
        "evs":[252,0,0,6,0,252],
        "moves":["leaf-blade","dragon-claw","earthquake","x-scissor"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sceptile @ Sitrus Berry"* ]]
    [[ "$output" == *"Ability: Overgrow"* ]]
    [[ "$output" == *"Level: 42"* ]]
    [[ "$output" == *"Shiny: Yes"* ]]
    [[ "$output" == *"Adamant Nature"* ]]
    [[ "$output" == *"EVs: 252 HP / 6 SpA / 252 Spe"* ]]
    [[ "$output" == *"IVs: 31 HP / 28 Atk / 19 Def / 31 SpA / 24 SpD / 30 Spe"* ]]
    [[ "$output" == *"- Leaf Blade"* ]]
    [[ "$output" == *"- Dragon Claw"* ]]
}

@test "showdown_format: held_item renders titlecased with no Berry suffix" {
    local enc='{
        "species":"snorlax","level":50,"nature":"adamant","ability":"thick-fat",
        "is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"held_item":"leftovers",
        "ivs":[31,31,31,31,31,31],"evs":[0,0,0,0,0,0],"moves":["body-slam"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Snorlax @ Leftovers"* ]]
    [[ "$output" != *"Leftovers Berry"* ]]
}

@test "showdown_format: held_item hyphen slug titlecased" {
    local enc='{
        "species":"kingdra","level":50,"nature":"modest","ability":"swift-swim",
        "is_hidden_ability":0,"gender":"F","shiny":0,"held_berry":null,"held_item":"choice-band",
        "ivs":[31,31,31,31,31,31],"evs":[0,0,0,0,0,0],"moves":["surf"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kingdra @ Choice Band"* ]]
}

@test "showdown_format: held_item -berry slug gets single Berry word" {
    local enc='{
        "species":"garchomp","level":50,"nature":"jolly","ability":"rough-skin",
        "is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,"held_item":"occa-berry",
        "ivs":[31,31,31,31,31,31],"evs":[0,0,0,0,0,0],"moves":["earthquake"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Garchomp @ Occa Berry"* ]]
    [[ "$output" != *"Berry Berry"* ]]
}

@test "showdown_format: held_item takes precedence over held_berry" {
    local enc='{
        "species":"gengar","level":50,"nature":"timid","ability":"levitate",
        "is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":"sitrus","held_item":"life-orb",
        "ivs":[31,31,31,31,31,31],"evs":[0,0,0,0,0,0],"moves":["shadow-ball"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gengar @ Life Orb"* ]]
    [[ "$output" != *"Sitrus"* ]]
}

@test "showdown_format: no berry, not shiny, no item line, no Shiny line" {
    local enc='{
        "species":"zubat","level":7,"nature":"timid","ability":"inner-focus",
        "is_hidden_ability":0,"gender":"M","shiny":0,"held_berry":null,
        "ivs":[10,20,30,15,5,25],
        "evs":[0,0,0,0,0,0],
        "moves":["leech-life","supersonic"]
    }'
    run showdown_format "$enc"
    [ "$status" -eq 0 ]
    [[ "$output" != *"@ "* ]]
    [[ "$output" != *"Shiny:"* ]]
    [[ "$output" == *"Zubat"* ]]
}
