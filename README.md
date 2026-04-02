# ⚡ suki-prompt

Simple, fast and minimially customizable zsh prompt based on
[gitstatus](https://github.com/romkatv/gitstatus).

![preview](./assets/carbon.png)

> [!IMPORTANT]
> gitstatus officially went on life support on June 6, 2024, although it is
> working properly as of today and will probably do so for an almost indefinite
> period of time.

## Why? 🤔

I oscillated between **Starship** and **Powerlevel10k** for my zsh prompt.
**Starship** is customizable and visually appealing by default but has
unnecessary features, making it slower. **Powerlevel10k** is extremely fast but
has a complex configuration as has recently been abandoned.

**Suki-prompt** combines Starship's style and Powerlevel10k's efficiency. It
uses **gitstatus** (like Powerlevel10k) for optimized git info, ensuring
**instant responsiveness** with no lag.

## Installation ⚙️

### [Zap](https://github.com/zap-zsh/zap)

```sh
plug "romkatv/gitstatus"
plug "justinstitt/suki-prompt"
```

## Customization 🎨

As suki-prompt is built with simplicity and speed in mind, there isn't too
much customization available. However, you can change the prompt's character
symbol and color, and add custom right-aligned segments.

```sh
SUKI_PROMPT_CHAR="➜"              # default value: "❯"

SUKI_PROMPT_CHAR_COLOR="green"    # default value: "fg"
```

### Custom Right-Aligned Modules

You can add up to 7 custom modules to the right side of both prompt lines.

- `SUKI_PROMPT_TOP_RIGHT_MODULES`: Aligns on the same line as the filepath and git status (right-aligned).
- `SUKI_PROMPT_BOTTOM_RIGHT_MODULES`: Aligns on the same line as the prompt character (standard `RPROMPT`).
- `SUKI_PROMPT_POST_PATH_MODULES`: Appears on the top line after the path and git info, before the right-aligned top-right modules.

#### Caching & Asynchronicity

If a module's output is static or expensive to calculate, you can optimize it using 0-based indexing:

**Caching** (calculate once per session):
- `SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE=(idx ...)`
- `SUKI_PROMPT_BOTTOM_RIGHT_MODULE_CACHE=(idx ...)`
- `SUKI_PROMPT_POST_PATH_MODULE_CACHE=(idx ...)`

**Asynchronicity** (calculate in background to prevent prompt lag):
- `SUKI_PROMPT_TOP_RIGHT_MODULE_ASYNC=(idx ...)`
- `SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC=(idx ...)`
- `SUKI_PROMPT_POST_PATH_MODULE_ASYNC=(idx ...)`

#### Example Configuration

```zsh
# Top line: Date (dynamic), Python version (cached)
SUKI_PROMPT_TOP_RIGHT_MODULES=('date +%H:%M:%S' 'python --version')
SUKI_PROMPT_TOP_RIGHT_MODULE_CACHE=(1)

# Bottom line: Expensive script (async)
SUKI_PROMPT_BOTTOM_RIGHT_MODULES=('~/scripts/my-slow-script.sh')
SUKI_PROMPT_BOTTOM_RIGHT_MODULE_ASYNC=(0)

# Post-path: Show user@host after path and git info
SUKI_PROMPT_POST_PATH_MODULES=('echo "as $(whoami)@$(hostname)"')
```

#### Performance Tracking

You can use the `prompt-timings` command to see a breakdown of how long each module takes to execute in milliseconds. This is useful for identifying slow commands that should be cached.

```text
suki-prompt module timings (ms):

Top Right Modules:
  [0] date +%H:%M:%S                     1.23 ms
  [1] python --version                  45.67 ms (cached)

Bottom Right Modules:
  [0] echo $VIRTUAL_ENV                  0.45 ms
```

## Thanks to

- [romkatv](https://github.com/romkatv) for gitsatus.
- [Starship](https://starship.rs/) for inspiration.
