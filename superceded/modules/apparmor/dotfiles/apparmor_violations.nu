let now = (date now)
let one_month_ago = ($now | date -1mo)

journalctl --since $"($one_month_ago)" --no-pager -g "apparmor=" 
| lines 
| filter {|line| $line =~ "apparmor=\"DENIED\"" and $line =~ "complain" } 
| parse -r '^(?<datetime>[^ ]+ [^ ]+) .*apparmor="DENIED".*profile="(?<profile>[^"]+)" .*name="(?<path>[^"]+)".*requested_mask="(?<mask>[^"]+)".*'
| update profile {|row|
    if $row.profile =~ '^/usr/lib/systemd/system/' {
        $row.profile | split row '/' | last | str replace '.service' ''
    } else {
        $row.profile
    }
}
| reject null
| group-by path
| each {|group|
    let services = ($group | get profile | uniq | str join ',')
    let count = ($group | length)
    let latest = ($group | get datetime | sort | last)
    let types = ($group | get mask | uniq | str join '+')

    {
      path: $group.0.path
      services: $services
      count: $count
      type: $types
      latest: $latest
    }
}
| sort-by -r latest
| to csv
| save --force ./apparmor_violations.csv
