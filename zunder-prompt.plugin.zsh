# Check if gitstatus is available.
if ! typeset -f gitstatus_query > /dev/null; then
  echo "The gitstatus plugin is not installed and is required" \
       "to use zunder-prompt."
  return 0
fi

# Load datetime for precise timing
zmodload zsh/datetime

# Internal storage for cache, timings, and async values
typeset -gA _ZUNDER_CACHE_TOP
typeset -gA _ZUNDER_CACHE_BOTTOM
typeset -gA _ZUNDER_TIMINGS_TOP
typeset -gA _ZUNDER_TIMINGS_BOTTOM
typeset -g  _ZUNDER_TIMINGS_GIT=0

typeset -gA _ZUNDER_ASYNC_TOP_VALS
typeset -gA _ZUNDER_ASYNC_BOTTOM_VALS

# Async infrastructure
typeset -g _ZUNDER_GIT_FD
typeset -g _ZUNDER_TOP_ASYNC_FD
typeset -g _ZUNDER_BOTTOM_ASYNC_FD

function _zunder_gitstatus_format() {
  emulate -L zsh
  [[ $VCS_STATUS_RESULT == 'ok-sync' ]] || return 1

  local      clean='%5F'
  local   modified='%3F'
  local  untracked='%4F'
  local conflicted='%1F'

  [[ "$TERM" != "linux" ]] && local git_icon=" "
  local p="on %B${clean}${git_icon}"

  local where
  if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
    where=$VCS_STATUS_LOCAL_BRANCH
  elif [[ -n $VCS_STATUS_TAG ]]; then
    p+='#'
    where=$VCS_STATUS_TAG
  else
    p+='@'
    where=${VCS_STATUS_COMMIT[1,8]}
  fi

  (( $#where > 32 )) && where[13,-13]="…"
  p+="${where//\%/%%}%b"

  (( VCS_STATUS_COMMITS_BEHIND )) && p+=" ${clean}⇣${VCS_STATUS_COMMITS_BEHIND}"
  (( VCS_STATUS_COMMITS_AHEAD && !VCS_STATUS_COMMITS_BEHIND )) && p+=" "
  (( VCS_STATUS_COMMITS_AHEAD  )) && p+="${clean}⇡${VCS_STATUS_COMMITS_AHEAD}"
  (( VCS_STATUS_PUSH_COMMITS_BEHIND )) && p+=" ${clean}⇠${VCS_STATUS_PUSH_COMMITS_BEHIND}"
  (( VCS_STATUS_PUSH_COMMITS_AHEAD && !VCS_STATUS_PUSH_COMMITS_BEHIND )) && p+=" "
  (( VCS_STATUS_PUSH_COMMITS_AHEAD  )) && p+="${clean}⇢${VCS_STATUS_PUSH_COMMITS_AHEAD}"
  (( VCS_STATUS_STASHES        )) && p+=" ${clean}*${VCS_STATUS_STASHES}"
  [[ -n $VCS_STATUS_ACTION     ]] && p+=" ${conflicted}${VCS_STATUS_ACTION}"
  (( VCS_STATUS_NUM_CONFLICTED )) && p+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"
  (( VCS_STATUS_NUM_STAGED     )) && p+=" ${modified}+${VCS_STATUS_NUM_STAGED}"
  (( VCS_STATUS_NUM_UNSTAGED   )) && p+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}"
  (( VCS_STATUS_NUM_UNTRACKED  )) && p+=" ${untracked}?${VCS_STATUS_NUM_UNTRACKED}"

  local prompt_str="${p}%f"
  local prompt_len="${(m)#${${${prompt_str//\%\%/x}//\%(f|<->F)}//\%[Bb]}}"
  echo "${prompt_len}|${prompt_str}"
}

function _zunder_recalculate_layout() {
  emulate -L zsh
  local git_len=0
  [[ -n "$GITSTATUS_PROMPT" ]] && git_len=$(( GITSTATUS_PROMPT_LEN + 1 ))

  local right_len=0
  [[ -n "$ZUNDER_TOP_RIGHT_PROMPT" ]] && right_len=$ZUNDER_TOP_RIGHT_PROMPT_LEN

  local total_right_len=$(( git_len + (right_len > 0 ? right_len + 1 : 0) ))
  typeset -g ZUNDER_TOP_LINE_RIGHT_LEN=$total_right_len

  local path_max_len=$(( COLUMNS - total_right_len ))
  (( path_max_len < 10 )) && path_max_len=10

  local expanded_path="${(%):-%${path_max_len}<…<%~%<<}"
  local path_len="${(m)#expanded_path}"

  typeset -g ZUNDER_TOP_LINE_PAD_LEN=0
  if (( right_len > 0 )); then
    ZUNDER_TOP_LINE_PAD_LEN=$(( COLUMNS - path_len - git_len - right_len ))
    (( ZUNDER_TOP_LINE_PAD_LEN < 1 )) && ZUNDER_TOP_LINE_PAD_LEN=1
  fi
}

function _zunder_gitstatus_callback() {
  emulate -L zsh
  local fd=$1 data
  if read -u $fd data 2>/dev/null; then
    if [[ -n "$data" ]]; then
      # format: len|str|timing
      typeset -g GITSTATUS_PROMPT_LEN="${data%%|*}"
      local rest="${data#*|}"
      typeset -g GITSTATUS_PROMPT="${rest%|*}"
      typeset -g _ZUNDER_TIMINGS_GIT="${rest##*|}"
      
      _zunder_recalculate_layout
      [[ -o zle ]] && zle reset-prompt
    fi
  fi
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  [[ "$_ZUNDER_GIT_FD" == "$fd" ]] && _ZUNDER_GIT_FD=
}

function _zunder_module_async_callback() {
  emulate -L zsh
  local fd=$1 side=$2 data
  if read -u $fd data 2>/dev/null; then
    # format: idx|val|timing
    local idx="${data%%|*}"
    local rest="${data#*|}"
    local val="${rest%%|*}"
    local timing="${rest#*|}"
    
    if [[ "$side" == "top" ]]; then
      _ZUNDER_ASYNC_TOP_VALS[$idx]="$val"
      _ZUNDER_TIMINGS_TOP[$idx]="$timing"
      if (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((idx-1))]} )); then
        _ZUNDER_CACHE_TOP[$idx]="$val"
      fi
    else
      _ZUNDER_ASYNC_BOTTOM_VALS[$idx]="$val"
      _ZUNDER_TIMINGS_BOTTOM[$idx]="$timing"
      if (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((idx-1))]} )); then
        _ZUNDER_CACHE_BOTTOM[$idx]="$val"
      fi
    fi
    
    zunder_right_prompt_update
    [[ -o zle ]] && zle reset-prompt
  fi
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  [[ "$side" == "top" && "$_ZUNDER_TOP_ASYNC_FD" == "$fd" ]] && _ZUNDER_TOP_ASYNC_FD=
  [[ "$side" == "bottom" && "$_ZUNDER_BOTTOM_ASYNC_FD" == "$fd" ]] && _ZUNDER_BOTTOM_ASYNC_FD=
}

function _zunder_top_module_async_callback() { _zunder_module_async_callback $1 "top" }
function _zunder_bottom_module_async_callback() { _zunder_module_async_callback $1 "bottom" }

function zunder_gitstatus_async_start() {
  emulate -L zsh
  [[ -n "$_ZUNDER_GIT_FD" ]] && { zle -F $_ZUNDER_GIT_FD 2>/dev/null; exec {_ZUNDER_GIT_FD}<&-; _ZUNDER_GIT_FD=; }
  local fd
  if exec {fd}< <(
    local start=$EPOCHREALTIME
    if gitstatus_query 'MY'; then
      local end=$EPOCHREALTIME
      echo "$(_zunder_gitstatus_format)|$(( (end - start) * 1000 ))"
    fi
  ); then
    _ZUNDER_GIT_FD=$fd
    zle -F $fd _zunder_gitstatus_callback
  fi
}

function gitstatus_prompt_update() {
  typeset -g GITSTATUS_PROMPT=''
  typeset -g GITSTATUS_PROMPT_LEN=0
  zunder_gitstatus_async_start
}

# Configuration Arrays
if ! (( ${+ZUNDER_PROMPT_TOP_RIGHT_MODULES} )); then typeset -ga ZUNDER_PROMPT_TOP_RIGHT_MODULES; ZUNDER_PROMPT_TOP_RIGHT_MODULES=(); fi
if ! (( ${+ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE} )); then typeset -ga ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE; ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE=(); fi
if ! (( ${+ZUNDER_PROMPT_TOP_RIGHT_MODULE_ASYNC} )); then typeset -ga ZUNDER_PROMPT_TOP_RIGHT_MODULE_ASYNC; ZUNDER_PROMPT_TOP_RIGHT_MODULE_ASYNC=(); fi

if ! (( ${+ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES} )); then typeset -ga ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES; ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES=(); fi
if ! (( ${+ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE} )); then typeset -ga ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE; ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE=(); fi
if ! (( ${+ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC} )); then typeset -ga ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC; ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC=(); fi

function zunder_right_prompt_update() {
  emulate -L zsh
  local module output i start end fd

  # Top right modules
  local -a top_segments
  i=0
  for module in "${ZUNDER_PROMPT_TOP_RIGHT_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && [[ -n "${_ZUNDER_CACHE_TOP[$i]}" ]]; then
      output="${_ZUNDER_CACHE_TOP[$i]}"
    elif (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )); then
      if [[ -n "${_ZUNDER_ASYNC_TOP_VALS[$i]}" ]]; then
        output="${_ZUNDER_ASYNC_TOP_VALS[$i]}"
      else
        output=""
        exec {fd}< <(
          local s=$EPOCHREALTIME
          local v=$(eval "$module" 2>/dev/null)
          local e=$EPOCHREALTIME
          echo "$i|$v|$(( (e-s)*1000 ))"
        )
        zle -F $fd _zunder_top_module_async_callback
      fi
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _ZUNDER_TIMINGS_TOP[$i]=$(( (end - start) * 1000 ))
      (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && _ZUNDER_CACHE_TOP[$i]="$output"
    fi
    [[ -n "$output" ]] && top_segments+=("${output}")
  done
  typeset -g ZUNDER_TOP_RIGHT_PROMPT="${(j: :)top_segments}"
  typeset -gi ZUNDER_TOP_RIGHT_PROMPT_LEN="${(m)#${${${ZUNDER_TOP_RIGHT_PROMPT//\%\%/x}//\%(f|<->F)}//\%[Bb]}}"

  # Bottom right modules (RPROMPT)
  local -a bottom_segments
  i=0
  for module in "${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && [[ -n "${_ZUNDER_CACHE_BOTTOM[$i]}" ]]; then
      output="${_ZUNDER_CACHE_BOTTOM[$i]}"
    elif (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )); then
      if [[ -n "${_ZUNDER_ASYNC_BOTTOM_VALS[$i]}" ]]; then
        output="${_ZUNDER_ASYNC_BOTTOM_VALS[$i]}"
      else
        output=""
        exec {fd}< <(
          local s=$EPOCHREALTIME
          local v=$(eval "$module" 2>/dev/null)
          local e=$EPOCHREALTIME
          echo "$i|$v|$(( (e-s)*1000 ))"
        )
        zle -F $fd _zunder_bottom_module_async_callback
      fi
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _ZUNDER_TIMINGS_BOTTOM[$i]=$(( (end - start) * 1000 ))
      (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && _ZUNDER_CACHE_BOTTOM[$i]="$output"
    fi
    [[ -n "$output" ]] && bottom_segments+=("${output}")
  done
  typeset -g RPROMPT="${(j: :)bottom_segments}"

  _zunder_recalculate_layout
}

function prompt-timings() {
  local i
  print "zunder-prompt module timings (ms):"
  printf "\nCore Components:\n"
  printf "  %-33s %10.2f ms (async)\n" "gitstatus_query" "${_ZUNDER_TIMINGS_GIT:-0}"

  if (( ${#ZUNDER_PROMPT_TOP_RIGHT_MODULES} > 0 )); then
    print "\nTop Right Modules:"
    for i in {1..${#ZUNDER_PROMPT_TOP_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${ZUNDER_PROMPT_TOP_RIGHT_MODULES[$i]}" "${_ZUNDER_TIMINGS_TOP[$i]:-0}"
      (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )) && printf " (async)"
      print
    done
  fi

  if (( ${#ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES} > 0 )); then
    print "\nBottom Right Modules:"
    for i in {1..${#ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES[$i]}" "${_ZUNDER_TIMINGS_BOTTOM[$i]:-0}"
      (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )) && printf " (async)"
      print
    done
  fi
}

gitstatus_stop 'MY' && gitstatus_start -s -1 -u -1 -c -1 -d -1 'MY'

function check_first_prompt() {
  if [[ $FIRST_PROMPT == false ]]; then printf "\n"; else FIRST_PROMPT=false; fi
}

function _zunder_clear_async_vals() {
  local i
  for i in "${(k)_ZUNDER_ASYNC_TOP_VALS[@]}"; do
    if ! (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then unset "_ZUNDER_ASYNC_TOP_VALS[$i]"; fi
  done
  for i in "${(k)_ZUNDER_ASYNC_BOTTOM_VALS[@]}"; do
    if ! (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then unset "_ZUNDER_ASYNC_BOTTOM_VALS[$i]"; fi
  done
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd gitstatus_prompt_update
add-zsh-hook precmd _zunder_clear_async_vals
add-zsh-hook precmd zunder_right_prompt_update
add-zsh-hook precmd check_first_prompt

setopt no_prompt_bang prompt_percent prompt_subst
[[ -z "$ZUNDER_PROMPT_CHAR" ]] && { ZUNDER_PROMPT_CHAR='%B❯%b'; [[ "$TERM" == "linux" ]] && ZUNDER_PROMPT_CHAR='>'; }
ZUNDER_PROMPT_CHAR_COLOR="fg"
PROMPT2="%8F·%f "
_ZUNDER_PATH_TRUNC_VAL='$(( (COLUMNS - ZUNDER_TOP_LINE_RIGHT_LEN) < 10 ? 10 : (COLUMNS - ZUNDER_TOP_LINE_RIGHT_LEN) ))'
PROMPT='%B%6F%${(e)_ZUNDER_PATH_TRUNC_VAL}<…<%~%<<%f%b'
PROMPT+='${GITSTATUS_PROMPT:+ $GITSTATUS_PROMPT}'
PROMPT+='${ZUNDER_TOP_RIGHT_PROMPT:+${(r:ZUNDER_TOP_LINE_PAD_LEN:: :)}$ZUNDER_TOP_RIGHT_PROMPT}'
PROMPT+=$'\n'
PROMPT+='%F{%(?.${ZUNDER_PROMPT_CHAR_COLOR}.red)}${ZUNDER_PROMPT_CHAR}%f '
