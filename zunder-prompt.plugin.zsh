# Check if gitstatus is available.
if ! typeset -f gitstatus_query > /dev/null; then
  echo "The gitstatus plugin is not installed and is required" \
       "to use zunder-prompt."
  return 0
fi

# Load datetime for precise timing
zmodload zsh/datetime

# Internal storage for cache and timings
typeset -gA _ZUNDER_CACHE_TOP
typeset -gA _ZUNDER_CACHE_BOTTOM
typeset -gA _ZUNDER_TIMINGS_TOP
typeset -gA _ZUNDER_TIMINGS_BOTTOM
typeset -g  _ZUNDER_TIMINGS_GIT=0

# Async infrastructure for git status
typeset -g _ZUNDER_GIT_FD
typeset -g _ZUNDER_GIT_PID

function _zunder_gitstatus_format() {
  emulate -L zsh
  # This function expects VCS_STATUS_* variables to be set.
  [[ $VCS_STATUS_RESULT == 'ok-sync' ]] || return 1

  local      clean='%5F'  # magenta foreground
  local   modified='%3F'  # yellow foreground
  local  untracked='%4F'  # blue foreground
  local conflicted='%1F'  # red foreground

  [[ "$TERM" != "linux" ]] && local git_icon=" " # set git_icon if not in tty
  local p="on %B${clean}${git_icon}"

  local where  # branch name, tag or commit
  if [[ -n $VCS_STATUS_LOCAL_BRANCH ]]; then
    where=$VCS_STATUS_LOCAL_BRANCH
  elif [[ -n $VCS_STATUS_TAG ]]; then
    p+='#'
    where=$VCS_STATUS_TAG
  else
    p+='@'
    where=${VCS_STATUS_COMMIT[1,8]}
  fi

  (( $#where > 32 )) && where[13,-13]="…"  # truncate long branch names and tags
  p+="${where//\%/%%}%b"                   # escape %

  # ⇣42 if behind the remote.
  (( VCS_STATUS_COMMITS_BEHIND )) && p+=" ${clean}⇣${VCS_STATUS_COMMITS_BEHIND}"
  # ⇡42 if ahead of the remote; no leading space if also behind the remote: ⇣42⇡42.
  (( VCS_STATUS_COMMITS_AHEAD && !VCS_STATUS_COMMITS_BEHIND )) && p+=" "
  (( VCS_STATUS_COMMITS_AHEAD  )) && p+="${clean}⇡${VCS_STATUS_COMMITS_AHEAD}"
  # ⇠42 if behind the push remote.
  (( VCS_STATUS_PUSH_COMMITS_BEHIND )) && p+=" ${clean}⇠${VCS_STATUS_PUSH_COMMITS_BEHIND}"
  (( VCS_STATUS_PUSH_COMMITS_AHEAD && !VCS_STATUS_PUSH_COMMITS_BEHIND )) && p+=" "
  # ⇢42 if ahead of the push remote; no leading space if also behind: ⇠42⇢42.
  (( VCS_STATUS_PUSH_COMMITS_AHEAD  )) && p+="${clean}⇢${VCS_STATUS_PUSH_COMMITS_AHEAD}"
  # *42 if have stashes.
  (( VCS_STATUS_STASHES        )) && p+=" ${clean}*${VCS_STATUS_STASHES}"
  # 'merge' if the repo is in an unusual state.
  [[ -n $VCS_STATUS_ACTION     ]] && p+=" ${conflicted}${VCS_STATUS_ACTION}"
  # ~42 if have merge conflicts.
  (( VCS_STATUS_NUM_CONFLICTED )) && p+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"
  # +42 if have staged changes.
  (( VCS_STATUS_NUM_STAGED     )) && p+=" ${modified}+${VCS_STATUS_NUM_STAGED}"
  # !42 if have unstaged changes.
  (( VCS_STATUS_NUM_UNSTAGED   )) && p+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}"
  # ?42 if have untracked files. It's really a question mark, your font isn't broken.
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
  local fd=$1
  local data
  
  if read -u $fd data 2>/dev/null; then
    if [[ -n "$data" ]]; then
      typeset -g GITSTATUS_PROMPT_LEN="${data%%|*}"
      typeset -g GITSTATUS_PROMPT="${data#*|}"
      # Recalculate layout now that we have git info
      _zunder_recalculate_layout
      # Refresh the prompt if ZLE is active
      [[ -o zle ]] && zle reset-prompt
    fi
  fi

  # Clean up
  zle -F $fd 2>/dev/null
  exec {fd}<&-
  [[ "$_ZUNDER_GIT_FD" == "$fd" ]] && _ZUNDER_GIT_FD=
}

function zunder_gitstatus_async_start() {
  emulate -L zsh
  
  # Close previous FD if it exists
  if [[ -n "$_ZUNDER_GIT_FD" ]]; then
    zle -F $_ZUNDER_GIT_FD 2>/dev/null
    exec {_ZUNDER_GIT_FD}<&-
    _ZUNDER_GIT_FD=
  fi

  # Create a pipe/subshell
  local fd
  if exec {fd}< <(
    if gitstatus_query 'MY'; then
      _zunder_gitstatus_format
    fi
  ); then
    _ZUNDER_GIT_FD=$fd
    zle -F $fd _zunder_gitstatus_callback
  fi
}

function gitstatus_prompt_update() {
  # Reset git info initially
  typeset -g GITSTATUS_PROMPT=''
  typeset -g GITSTATUS_PROMPT_LEN=0
  
  # Trigger async update
  zunder_gitstatus_async_start
}

# Right-aligned prompt modules for the top line (with filepath).
if ! (( ${+ZUNDER_PROMPT_TOP_RIGHT_MODULES} )); then
  typeset -ga ZUNDER_PROMPT_TOP_RIGHT_MODULES
  ZUNDER_PROMPT_TOP_RIGHT_MODULES=()
fi

# Indices of top modules to cache.
if ! (( ${+ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE} )); then
  typeset -ga ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE
  ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE=()
fi

# Right-aligned prompt modules for the bottom line.
if ! (( ${+ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES} )); then
  typeset -ga ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES
  ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES=()
fi

# Indices of bottom modules to cache.
if ! (( ${+ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE} )); then
  typeset -ga ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE
  ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE=()
fi

function zunder_right_prompt_update() {
  emulate -L zsh
  local module output i start end

  # Top right modules
  local -a top_segments
  i=0
  for module in "${ZUNDER_PROMPT_TOP_RIGHT_MODULES[@]}"; do
    (( i++ )); [[ $i -gt 7 ]] && break

    if (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then
      if [[ -z "${_ZUNDER_CACHE_TOP[$i]}" ]]; then
        start=$EPOCHREALTIME
        _ZUNDER_CACHE_TOP[$i]=$(eval "$module" 2>/dev/null)
        end=$EPOCHREALTIME
        _ZUNDER_TIMINGS_TOP[$i]=$(( (end - start) * 1000 ))
      fi
      output="${_ZUNDER_CACHE_TOP[$i]}"
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _ZUNDER_TIMINGS_TOP[$i]=$(( (end - start) * 1000 ))
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

    if (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )); then
      if [[ -z "${_ZUNDER_CACHE_BOTTOM[$i]}" ]]; then
        start=$EPOCHREALTIME
        _ZUNDER_CACHE_BOTTOM[$i]=$(eval "$module" 2>/dev/null)
        end=$EPOCHREALTIME
        _ZUNDER_TIMINGS_BOTTOM[$i]=$(( (end - start) * 1000 ))
      fi
      output="${_ZUNDER_CACHE_BOTTOM[$i]}"
    else
      start=$EPOCHREALTIME
      output=$(eval "$module" 2>/dev/null)
      end=$EPOCHREALTIME
      _ZUNDER_TIMINGS_BOTTOM[$i]=$(( (end - start) * 1000 ))
    fi

    [[ -n "$output" ]] && bottom_segments+=("${output}")
  done
  typeset -g RPROMPT="${(j: :)bottom_segments}"

  # Initial layout calculation (Git will be empty here)
  _zunder_recalculate_layout
}

function prompt-timings() {
  local i
  print "zunder-prompt module timings (ms):"
  
  printf "\nCore Components:\n"
  printf "  %-33s %10s (Async)\n" "gitstatus_query" "-"

  if (( ${#ZUNDER_PROMPT_TOP_RIGHT_MODULES} > 0 )); then
    print "\nTop Right Modules:"
    for i in {1..${#ZUNDER_PROMPT_TOP_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${ZUNDER_PROMPT_TOP_RIGHT_MODULES[$i]}" "${_ZUNDER_TIMINGS_TOP[$i]:-0}"
      (( ${ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      print
    done
  fi

  if (( ${#ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES} > 0 )); then
    print "\nBottom Right Modules:"
    for i in {1..${#ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES}}; do
      [[ $i -gt 7 ]] && break
      printf "  [%d] %-30s %10.2f ms" $((i-1)) "${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES[$i]}" "${_ZUNDER_TIMINGS_BOTTOM[$i]:-0}"
      (( ${ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE[(I)$((i-1))]} )) && printf " (cached)"
      print
    done
  fi
}

# Start gitstatusd instance with name "MY".
gitstatus_stop 'MY' && gitstatus_start -s -1 -u -1 -c -1 -d -1 'MY'

function check_first_prompt() {
  if [[ $FIRST_PROMPT == false ]]; then
    printf "\n"
  else
    FIRST_PROMPT=false
  fi
}

autoload -Uz add-zsh-hook

# On every prompt, trigger async git status update.
add-zsh-hook precmd gitstatus_prompt_update

# Updates the right prompt.
add-zsh-hook precmd zunder_right_prompt_update

# Adds a new line if it's not the first prompt.
add-zsh-hook precmd check_first_prompt

# Enable/disable the right prompt options.
setopt no_prompt_bang prompt_percent prompt_subst

# Default prompt char
if [[ -z "$ZUNDER_PROMPT_CHAR" ]]; then
  ZUNDER_PROMPT_CHAR='%B❯%b'
  [[ "$TERM" == "linux" ]] && ZUNDER_PROMPT_CHAR='>'  # switch to > in tty mode
fi

# Default prompt char color (uses terminal foreground color)
ZUNDER_PROMPT_CHAR_COLOR="fg"

# Prompt used in multiline commands
PROMPT2="%8F·%f "

# Use a conservative truncation value for the path
_ZUNDER_PATH_TRUNC_VAL='$(( (COLUMNS - ZUNDER_TOP_LINE_RIGHT_LEN) < 10 ? 10 : (COLUMNS - ZUNDER_TOP_LINE_RIGHT_LEN) ))'

# Cyan current working directory.
PROMPT='%B%6F%${(e)_ZUNDER_PATH_TRUNC_VAL}<…<%~%<<%f%b'

# Git status
PROMPT+='${GITSTATUS_PROMPT:+ $GITSTATUS_PROMPT}'

# Top right modules (with padding to align to the right edge)
PROMPT+='${ZUNDER_TOP_RIGHT_PROMPT:+${(r:ZUNDER_TOP_LINE_PAD_LEN:: :)}$ZUNDER_TOP_RIGHT_PROMPT}'

# New line
PROMPT+=$'\n'

# $ZUNDER_PROMPT_CHAR $ZUNDER_PROMPT_CHAR_COLOR/red (ok/error)
PROMPT+='%F{%(?.${ZUNDER_PROMPT_CHAR_COLOR}.red)}${ZUNDER_PROMPT_CHAR}%f '
