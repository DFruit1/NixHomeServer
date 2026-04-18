# scripts/aa_gen_profiles.nu

use std log

let ATOMS = ($env.PWD | path join "apparmor-auto" "out" "atoms.csv")
let MAP   = ($env.PWD | path join "modules" "apparmor" "config" "map.toml")
let TPL   = ($env.PWD | path join "modules" "apparmor" "dotfiles" "profile_template.hbs")
let OUTD  = ($env.PWD | path join "apparmor-auto" "out" "profiles")

mkdir $OUTD | ignore

def atom_to_rule [path perms] {
  let clean = ($path | str replace -r '\\s+$' '' )
  let star  = (if ($clean | path type) == "dir" { $"($clean)/**" } else { $clean })
  $"$star ($perms),"
}

# Simple handlebars-ish renderer for {{name}}, {{#if}}, {{#each atoms}}
def render_tpl [name atoms policy: record] {
  let tpl = (open --raw $TPL)
  let with_name = ($tpl | str replace '{{name}}' $name)
  mut s = $with_name
  # if-blocks
  for k in ($policy | columns) {
    let p = ($policy | get $k)
    if $p == true {
      $s = ($s | str replace -a $"{{#if $k}}" '' | str replace -a $"{{/if}}" '')
    } else {
      $s = ($s | str replace -a -r $"(?s){{#if $k}}.*?{{/if}}" '')
    }
  }
  # atoms
  let atoms_blob = ($atoms | str join "\n  ")
  $s | str replace -a '{{#each atoms}}' '' | str replace -a '{{/each}}' '' | str replace -a '{{this}}' $atoms_blob
}

export def main [] {
  let atoms = (open $ATOMS | from csv)
  let cfg   = (open $MAP | from toml)

  mut rows_out = []

  for p in $cfg.profiles {
    let name = $p.name
    let comm_rx = ($p.match.comm_regex | default null)
    let exe_rx  = ($p.match.exe_regex  | default null)
    let hint    = ($p.match.hint_contains_path | default null)

    let mine = ($atoms
      | where {||
          let ok_comm = (if $comm_rx == null {false} else { $in.comm | str matches -r $comm_rx })
          let ok_exe  = (if $exe_rx  == null {false} else { $in.exe  | str matches -r $exe_rx })
          let ok_hint = (if $hint    == null {true}  else { $in.path | str contains $hint })
          $ok_hint and ($ok_comm or $ok_exe)
        }
      | select path perms | uniq)

    if ($mine | is-empty) {
      continue
    }

    let rules = ($mine | each {|r| atom_to_rule $r.path $r.perms })

    let policy = ($p.policy | default {})
    let profile_txt = (render_tpl $name $rules $policy)
    let outp = ($OUTD | path join $"($name).profile")
    $profile_txt | save -f $outp

    $rows_out ++= [{profile: $name, unit: ($p.unit | default ""), atoms: ($mine | length), path: $outp}]
  }

  $rows_out | sort-by profile | to md | print
}
