def main [git_credential_file: string, action: string] {
  let piped_buffer = $in | lines | append '' # ensure to have a last empty line
  let is_piped = $piped_buffer | is-not-empty

  let action = $action | str downcase
  if $action != 'get' {
    # ignore other actions
    return
  }

  mut query = {}
  for i in 0.. {
    let input = if $is_piped {
      $piped_buffer | get $i
    } else {
      input
    }
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

  # just ignore them for now (e.g. {capability[]: state, wwwauth[]: Basic realm="GitLab"})
  # if ($query | is-not-empty) {
  #   error make { msg: $'Unsupported query: ($query)' }
  # }

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
