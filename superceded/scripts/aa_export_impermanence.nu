# scripts/aa_export_impermanence.nu

let ATOMS = ($env.PWD | path join "apparmor-auto" "out" "atoms.csv")
let OUT   = ($env.PWD | path join "apparmor-auto" "out" "impermanence-autogen.nix")

export def main [] {
  let atoms = (open $ATOMS | from csv)
  let dirs = ($atoms
    | get path
    | each {|p| if ((path type $p) == "file") { (path dirname $p) } else { $p }}
    | uniq | sort)

  let nix = ''
# This file is generated. Import its lists into your impermanence module.
{
  # e.g. environment.persistence."/persist".directories ++= files;
  directories = [
'' + ($dirs | each {|d| $"    \"($d)\""} | str join "\n") + "\n  ];\n}\n"

  $nix | save -f $OUT
  print $"Wrote ($dirs | length) directories to apparmor-auto/out/impermanence-autogen.nix"
}
