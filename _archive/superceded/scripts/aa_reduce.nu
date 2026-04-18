# scripts/aa_reduce.nu

let IN = ($env.PWD | path join "apparmor-auto" "out" "denials.ndjson")
let OUT = ($env.PWD | path join "apparmor-auto" "out" "atoms.csv")

# map Linux/Audit masks to AppArmor rule suffix letters
def mask_to_perms [m: string] {
  # requested_mask could be like "r", "rw", "r::\"/file\""; keep letters
  let letters = ($m | str replace -r '[^rwmxk]' '' ) # r,w,m(=mmap),x(=exec),k(=lock)
  $letters
}

export def main [] {
  let rows = (open --raw $IN | from ndjson)
    | where name != null
    | update requested {|r| if ($r.requested == null) {""} else { mask_to_perms $r.requested } }
    | update name {|r| ($r.name | str trim)}

  let grouped = $rows
    | group-by {comm: ($in.comm | default $in.exe), exe: ($in.exe | default "")}
    | transpose k v
    | each {|g|
        let items = $g.v
        let bypath = ($items | group-by name | transpose path items
          | each {|p|
              let perms = ($p.items | get requested | compact | str join '' | split chars | uniq | str join '')
              {comm: ($items.0.comm | default $items.0.exe), exe: $items.0.exe, path: $p.path, perms: $perms}
            })
        $bypath
      } | flatten

  $grouped | to csv | save -f $OUT
  print $"Saved (open $OUT | from csv | length) atoms to apparmor-auto/out/atoms.csv"
}
