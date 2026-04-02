# Check if gitstatus is available.
if ! typeset -f gitstatus_query > /dev/null; then
  echo "The gitstatus plugin is not installed and is required" \
       "to use suki-prompt."
  return 0
fi

# Load datetime for precise timing
zmodload zsh/datetime

# Internal storage for cache, timings, and async values
typeset -gA _SUKI_CACHE_TOP
typeset -gA _SUKI_CACHE_BOTTOM
typeset -gA _SUKI_CACHE_POST_PATH
typeset -gA _SUKI_TIMINGS_TOP
typeset -gA _SUKI_TIMINGS_BOTTOM
typeset -gA _SUKI_TIMINGS_POST_PATH
typeset -g  _SUKI_TIMINGS_GIT=0

typeset -gA _SUKI_ASYNC_TOP_VALS
typeset -gA _SUKI_ASYNC_BOTTOM_VALS
typeset -gA _SUKI_ASYNC_POST_PATH_VALS

# Async infrastructure
typeset -g _SUKI_GIT_FD
typeset -g _SUKI_GIT_LOADING=1
typeset -g _SUKI_TOP_ASYNC_FD
typeset -g _SUKI_BOTTOM_ASYNC_FD
typeset -g _SUKI_POST_PATH_ASYNC_FD

function _suki_gitstatus_format() {
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
  local prompt_len="${(m)#${${${prompt_str//\%\%/x}//\%(f|k|<->[FK])}//\%[BbUuSs]}}"
  echo "${prompt_len}|${prompt_str}"
}

function _suki_recalculate_layout() {
  emulate -L zsh
  local git_len=0
  [[ -n "$GITSTATUS_PROMPT" ]] && git_len=$(( GITSTATUS_PROMPT_LEN + 1 ))

  local post_path_len=0
  [[ -n "$SUKI_POST_PATH_PROMPT" ]] && post_path_len=$(( SUKI_POST_PATH_PROMPT_LEN + 1 ))

  local right_len=0
  [[ -n "$SUKI_TOP_RIGHT_PROMPT" ]] && right_len=$SUKI_TOP_RIGHT_PROMPT_LEN

  local total_right_len=$(( git_len + post_path_len + (right_len > 0 ? right_len + 1 : 0) ))
  typeset -g SUKI_TOP_LINE_RIGHT_LEN=$total_right_len

  local path_max_len=$(( COLUMNS - total_right_len ))
  (( path_max_len < 10 )) && path_max_len=10

  local expanded_path="${(%):-%${path_max_len}<…<%~%<<}"
  local path_len="${(m)#expanded_path}"

  typeset -g SUKI_TOP_LINE_PAD_LEN=0
  if (( right_len > 0 )); then
    SUKI_TOP_LINE_PAD_LEN=$(( COLUMNS - path_len - git_len - post_path_len - right_len))
    (( SUKI_TOP_LINE_PAD_LEN < 1 )) && SUKI_TOP_LINE_PAD_LEN=1
  fi
}

function _suki_gitstatus_callback() {
  emulate -L zsh
  local fd=$1 data
  if read -u $fd data 2>/dev/null; then
    typeset -g _SUKI_GIT_LOADING=0
    if [[ -n "$data" ]]; then
      # format: len|str|timing
      typeset -g GITSTATUS_PROMPT_LEN="${data%%|*}"
      local rest="${data#*|}"
      typeset -g GITSTATUS_PROMPT="${rest%|*}"
      typeset -g _SUKI_TIMINGS_GIT="${rest##*|}"

      _suki_recalculate_layout
    fi
    [[ -o zle ]] && zle reset-prompt
  fi
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  [[ "$_SUKI_GIT_FD" == "$fd" ]] && _SUKI_GIT_FD=
}

function _suki_module_async_callback() {
  emulate -L zsh
  local fd=$1 side=$2 data
  if read -u $fd data 2>/dev/null; then
    # format: idx|val|timing
    local idx="${data%%|*}"
    local rest="${data#*|}"
    local val="${rest%%|*}"
    local timing="${rest#*|}"
    
    if [[ "$side" == "top" ]]; then
      _SUKI_ASYNC_TOP_VALS[$idx]="$val"
      _SUKI_TIMINGS_TOP[$idx]="$timing"
      if (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((idx-1))]} )); then
        _SUKI_CACHE_TOP[$idx]="$val"
      fi
    elif [[ "$side" == "post_path" ]]; then
      _SUKI_ASYNC_POST_PATH_VALS[$idx]="$val"
      _SUKI_TIMINGS_POST_PATH[$idx]="$timing"
      if (( ${SUKI_PROMPT_POST_PATH_MODULE_CACHE[(I)$((idx-1))]} )); then
        _SUKI_CACHE_POST_PATH[$idx]="$val"
      fi
    else
      _SUKI_ASYNC_BOTTOM_VALS[$idx]="$val"
      _SUKI_TIMINGS_BOTTOM[$idx]="$timing"
      if (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((idx-1))]} )); then
        _SUKI_CACHE_BOTTOM[$idx]="$val"
      fi
    fi
    
    suki_right_prompt_update
    [[ -o zle ]] && zle reset-prompt
  fi
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  [[ "$side" == "top" && "$_SUKI_TOP_ASYNC_FD" == "$fd" ]] && _SUKI_TOP_ASYNC_FD=
  [[ "$side" == "bottom" && "$_SUKI_BOTTOM_ASYNC_FD" == "$fd" ]] && _SUKI_BOTTOM_ASYNC_FD=
  [[ "$side" == "post_path" && "$_SUKI_POST_PATH_ASYNC_FD" == "$fd" ]] && _SUKI_POST_PATH_ASYNC_FD=
}

function _suki_top_module_async_callback() { _suki_module_async_callback $1 "top" }
function _suki_bottom_module_async_callback() { _suki_module_async_callback $1 "bottom" }
function _suki_post_path_module_async_callback() { _suki_module_async_callback $1 "post_path" }

function suki_gitstatus_async_start() {
  emulate -L zsh
  [[ -n "$_SUKI_GIT_FD" ]] && { zle -F $_SUKI_GIT_FD 2>/dev/null; exec {_SUKI_GIT_FD}<&-; _SUKI_GIT_FD=; }
  local fd
  if exec {fd}< <(
    local start=$EPOCHREALTIME
    if gitstatus_query 'MY'; then
      local end=$EPOCHREALTIME
      local fmt=$(_suki_gitstatus_format)
      if [[ -n "$fmt" ]]; then
        echo "${fmt}|$(( (end - start) * 1000 ))"
      else
        echo "0||$(( (end - start) * 1000 ))"
      fi
    else
      echo "0||0"
    fi
  ); then
    _SUKI_GIT_FD=$fd
    zle -F $fd _suki_gitstatus_callback
  fi
}

function gitstatus_prompt_update() {
  typeset -g GITSTATUS_PROMPT=''
  typeset -g GITSTATUS_PROMPT_LEN=0
  typeset -g _SUKI_GIT_LOADING=1
  suki_gitstatus_async_start
}

# Configuration Arrays
if ! (( ${+SUKI_PROMPT_TOP_RIGHT_MODULES} )); then typeset -ga SUKI_PROMPT_TOP_RIGHT_MODULES; SUKI_PROMPT_TOP_RIGHT_MODULES=(); fi
if ! (( ${+SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE} )); then typeset -ga SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE; SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE=(); fi
if ! (( ${+SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC} )); then typeset -ga SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC; SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC=(); fi

if ! (( ${+SUKI_PROMPT_BOTTOM_RIGHT_MODULES} )); then typeset -ga SUKI_PROMPT_BOTTOM_RIGHT_MODULES; SUKI_PROMPT_BOTTOM_RIGHT_MODULES=(); fi
if ! (( ${+SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE} )); then typeset -ga SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE; SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE=(); fi
if ! (( ${+SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC} )); then typeset -ga SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC; SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC=(); fi

if ! (( ${+SUKI_PROMPT_POST_PATH_MODULES} )); then typeset -ga SUKI_PROMPT_POST_PATH_MODULES; SUKI_PROMPT_POST_PATH_MODULES=(); fi
if ! (( ${+SUKI_PROMPT_POST_PATH_MODULE_CACHE} )); then typeset -ga SUKI_PROMPT_POST_PATH_MODULE_CACHE; SUKI_PROMPT_POST_PATH_MODULE_CACHE=(); fi
if ! (( ${+SUKI_PROMPT_POST_PATH_MODULE_ASYNC} )); then typeset -ga SUKI_PROMPT_POST_PATH_MODULE_ASYNC; SUKI_PROMPT_POST_PATH_MODULE_ASYNC=(); fi

function suki_right_prompt_update() {
  emulate -L zsh
  setopt extended_glob
  local module output i start end fd

  # Top right modules
  local -a top_segments
  i=0
  for module in "${SUKI_PROMPT_TOP_RIGHT_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && [[ -n "${_SUKI_CACHE_TOP[$i]}" ]]; then
      output="${_SUKI_CACHE_TOP[$i]}"
    elif (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )); then
      if (( ${+_SUKI_ASYNC_TOP_VALS[$i]} )); then
        output="${_SUKI_ASYNC_TOP_VALS[$i]}"
      else
        output=""
        exec {fd}< <(
          local s=$EPOCHREALTIME
          local v=$(eval "$module" 2>/dev/null)
          local e=$EPOCHREALTIME
          echo "$i|$v|$(( (e-s)*1000 ))"
        )
        zle -F $fd _suki_top_module_async_callback
      fi
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _SUKI_TIMINGS_TOP[$i]=$(( (end - start) * 1000 ))
      (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && _SUKI_CACHE_TOP[$i]="$output"
    fi
    [[ -n "$output" ]] && top_segments+=("${output}")
  done
  typeset -g SUKI_TOP_RIGHT_PROMPT="${(j: :)top_segments}"
  typeset -gi SUKI_TOP_RIGHT_PROMPT_LEN="${(m)#${${${SUKI_TOP_RIGHT_PROMPT//\%\%/x}//\%(f|k|<->[FK])}//\%[BbUuSs]}}"

  # Bottom right modules (RPROMPT)
  local -a bottom_segments
  i=0
  for module in "${SUKI_PROMPT_BOTTOM_RIGHT_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && [[ -n "${_SUKI_CACHE_BOTTOM[$i]}" ]]; then
      output="${_SUKI_CACHE_BOTTOM[$i]}"
    elif (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )); then
      if (( ${+_SUKI_ASYNC_BOTTOM_VALS[$i]} )); then
        output="${_SUKI_ASYNC_BOTTOM_VALS[$i]}"
      else
        output=""
        exec {fd}< <(
          local s=$EPOCHREALTIME
          local v=$(eval "$module" 2>/dev/null)
          local e=$EPOCHREALTIME
          echo "$i|$v|$(( (e-s)*1000 ))"
        )
        zle -F $fd _suki_bottom_module_async_callback
      fi
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _SUKI_TIMINGS_BOTTOM[$i]=$(( (end - start) * 1000 ))
      (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && _SUKI_CACHE_BOTTOM[$i]="$output"
    fi
    [[ -n "$output" ]] && bottom_segments+=("${output}")
  done
  typeset -g RPROMPT="${(j: :)bottom_segments}"

  # Post-path modules (appear after git info on top line)
  local -a post_path_segments
  i=0
  for module in "${SUKI_PROMPT_POST_PATH_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${SUKI_PROMPT_POST_PATH_MODULE_CACHE[(I)$((i-1))]} )) && [[ -n "${_SUKI_CACHE_POST_PATH[$i]}" ]]; then
      output="${_SUKI_CACHE_POST_PATH[$i]}"
    elif (( ${SUKI_PROMPT_POST_PATH_MODULE_ASYNC[(I)$((i-1))]} )); then
      if (( ${+_SUKI_ASYNC_POST_PATH_VALS[$i]} )); then
        output="${_SUKI_ASYNC_POST_PATH_VALS[$i]}"
      else
        output=""
        exec {fd}< <(
          local s=$EPOCHREALTIME
          local v=$(eval "$module" 2>/dev/null)
          local e=$EPOCHREALTIME
          echo "$i|$v|$(( (e-s)*1000 ))"
        )
        zle -F $fd _suki_post_path_module_async_callback
      fi
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _SUKI_TIMINGS_POST_PATH[$i]=$(( (end - start) * 1000 ))
      (( ${SUKI_PROMPT_POST_PATH_MODULE_CACHE[(I)$((i-1))]} )) && _SUKI_CACHE_POST_PATH[$i]="$output"
    fi
    [[ -n "$output" ]] && post_path_segments+=("${output}")
  done
  typeset -g SUKI_POST_PATH_PROMPT="${(j: :)post_path_segments}"
  typeset -gi SUKI_POST_PATH_PROMPT_LEN="${(m)#${${${SUKI_POST_PATH_PROMPT//\%\%/x}//\%(f|k|<->[FK])}//\%[BbUuSs]}}"

  _suki_recalculate_layout
}

function prompt-timings() {
  local i
  print "suki-prompt module timings (ms):"
  printf "\nCore Components:\n"
  printf "  %-33s %10.2f ms (async)\n" "gitstatus_query" "${_SUKI_TIMINGS_GIT:-0}"

  if (( ${#SUKI_PROMPT_TOP_RIGHT_MODULES} > 0 )); then
    print "\nTop Right Modules:"
    for i in {1..${#SUKI_PROMPT_TOP_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${SUKI_PROMPT_TOP_RIGHT_MODULES[$i]}" "${_SUKI_TIMINGS_TOP[$i]:-0}"
      (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )) && printf " (async)"
      print
    done
  fi

  if (( ${#SUKI_PROMPT_BOTTOM_RIGHT_MODULES} > 0 )); then
    print "\nBottom Right Modules:"
    for i in {1..${#SUKI_PROMPT_BOTTOM_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${SUKI_PROMPT_BOTTOM_RIGHT_MODULES[$i]}" "${_SUKI_TIMINGS_BOTTOM[$i]:-0}"
      (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC[(I)$((i-1))]} )) && printf " (async)"
      print
    done
  fi

  if (( ${#SUKI_PROMPT_POST_PATH_MODULES} > 0 )); then
    print "\nPost-Path Modules:"
    for i in {1..${#SUKI_PROMPT_POST_PATH_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${SUKI_PROMPT_POST_PATH_MODULES[$i]}" "${_SUKI_TIMINGS_POST_PATH[$i]:-0}"
      (( ${SUKI_PROMPT_POST_PATH_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      (( ${SUKI_PROMPT_POST_PATH_MODULE_ASYNC[(I)$((i-1))]} )) && printf " (async)"
      print
    done
  fi
}

gitstatus_stop 'MY' && gitstatus_start -s -1 -u -1 -c -1 -d -1 'MY'

function check_first_prompt() {
  if [[ $FIRST_PROMPT == false ]]; then printf "\n"; else FIRST_PROMPT=false; fi
}

function _suki_clear_async_vals() {
  local i
  for i in "${(k)_SUKI_ASYNC_TOP_VALS[@]}"; do
    if ! (( ${SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then unset "_SUKI_ASYNC_TOP_VALS[$i]"; fi
  done
  for i in "${(k)_SUKI_ASYNC_BOTTOM_VALS[@]}"; do
    if ! (( ${SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then unset "_SUKI_ASYNC_BOTTOM_VALS[$i]"; fi
  done
  for i in "${(k)_SUKI_ASYNC_POST_PATH_VALS[@]}"; do
    if ! (( ${SUKI_PROMPT_POST_PATH_MODULE_CACHE[(I)$((i-1))]} )); then unset "_SUKI_ASYNC_POST_PATH_VALS[$i]"; fi
  done
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd gitstatus_prompt_update
add-zsh-hook precmd _suki_clear_async_vals
add-zsh-hook precmd suki_right_prompt_update
add-zsh-hook precmd check_first_prompt

setopt no_prompt_bang prompt_percent prompt_subst
[[ -z "$SUKI_PROMPT_CHAR" ]] && { SUKI_PROMPT_CHAR='%B✦%b'; [[ "$TERM" == "linux" ]] && SUKI_PROMPT_CHAR='>'; }
SUKI_PROMPT_CHAR_COLOR="fg"
PROMPT2="%8F·%f "
_SUKI_PATH_TRUNC_VAL='$(( (COLUMNS - SUKI_TOP_LINE_RIGHT_LEN) < 10 ? 10 : (COLUMNS - SUKI_TOP_LINE_RIGHT_LEN) ))'
PROMPT='%B%6F%${(e)_SUKI_PATH_TRUNC_VAL}<…<%~%<<%f%b'
PROMPT+='${GITSTATUS_PROMPT:+ $GITSTATUS_PROMPT}'
PROMPT+='${SUKI_POST_PATH_PROMPT:+ $SUKI_POST_PATH_PROMPT}'
PROMPT+='${SUKI_TOP_RIGHT_PROMPT:+${(r:SUKI_TOP_LINE_PAD_LEN:: :)}$SUKI_TOP_RIGHT_PROMPT}'
PROMPT+=$'\n'
PROMPT+='%F{%(?.${SUKI_PROMPT_CHAR_COLOR}.red)}${SUKI_PROMPT_CHAR}%f '
