def main [git_credential_file: string] {
  let action = input | str downcase
  if $action != 'get' {
    error make { msg: $'Unsupported action: ($action)' }
  }

  mut query = {}
  loop {
    let input = input
    let parts = $input | split row '=' -n 2
    if ($parts | length) < 2 {
      break
    }
    $query = $query | upsert ($parts | get 0) ($parts | get 1)
  }

  let protocol = $query | get protocol
  $query = $query | reject protocol

  let host = $query | get host
  $query = $query | reject host

  if ($query | is-not-empty) {
    error make { msg: $'Unsupported query: ($query)' }
  }

  let credentials = open --raw $git_credential_file | from json

  let hit = $credentials
    | where protocol == $protocol and host == $host 
    | default 0 'priority'
    | sort-by 'priority' --reverse
    | reject 'priority'
  if ($hit | is-empty) {
    return
  }

  $hit | first | items { |k, v|
    $'($k)=($v)'
  } | str join "\n"
}
