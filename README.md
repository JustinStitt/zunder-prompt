# ⚡ zunder-prompt

Simple and fast zsh prompt based on [gitstatus](https://github.com/romkatv/gitstatus).

![preview](./assets/preview.svg)

> [!IMPORTANT]
> gitstatus officially went on life support on June 6, 2024, although it is
> working properly as of today and will probably do so for an almost indefinite
> period of time.

## Why? 🤔

I oscillated between **Starship** and **Powerlevel10k** for my zsh prompt.
**Starship** is customizable and visually appealing by default but has
unnecessary features, making it slower. **Powerlevel10k** is extremely fast but
has a complex configuration.

My goal was to create a prompt with only the **essential functionality**:
detecting command failures and displaying basic git repository info. I avoided
advanced customization to keep the code simple yet aesthetically pleasing.

**Zunder-prompt** combines Starship's style and Powerlevel10k's efficiency. It
uses **gitstatus** (like Powerlevel10k) for optimized git info, ensuring
**instant responsiveness** with no lag.

## Installation ⚙️

### [Zinit](https://github.com/zdharma-continuum/zinit)

```sh
zinit light-mode depth"1" for \
  romkatv/gitstatus \
  warbacon/zunder-prompt
```

### [Zap](https://github.com/zap-zsh/zap)

```sh
plug "romkatv/gitstatus"
plug "warbacon/zunder-prompt"
```

### [Zgenom](https://github.com/jandamm/zgenom)

```sh
if ! zgenom saved; then
  # ...
  zgenom load romkatv/gitstatus
  zgenom load warbacon/zunder-prompt
  # ...
fi
```

### [Zplug](https://github.com/zplug/zplug)

```sh
zplug "romkatv/gitstatus", depth:1
zplug "warbacon/zunder-prompt", on:"romkatv/gitstatus", depth=1
```

## Customization 🎨

As zunder-prompt is built with simplicity and speed in mind, there isn't too
much customization available. However, you can change the prompt's character
symbol and color, and add custom right-aligned segments.

```sh
ZUNDER_PROMPT_CHAR="➜"              # default value: "❯"

ZUNDER_PROMPT_CHAR_COLOR="green"    # default value: "fg"
```

### Custom Right-Aligned Modules

You can add up to 7 custom modules to the right side of both prompt lines.

- `ZUNDER_PROMPT_TOP_RIGHT_MODULES`: Aligns on the same line as the filepath and git status.
- `ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES`: Aligns on the same line as the prompt character (standard `RPROMPT`).

#### Caching

If a module's output is static or expensive to calculate, you can cache it to be evaluated only once per shell session using 0-based indexing:

- `ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE=(idx ...)`
- `ZUNDER_PROMPT_BOTTOM_RIGHT_MODULE_CACHE=(idx ...)`

#### Example Configuration

```zsh
# Top line: Date (dynamic), Python version (cached)
ZUNDER_PROMPT_TOP_RIGHT_MODULES=('date +%H:%M:%S' 'python --version')
ZUNDER_PROMPT_TOP_RIGHT_MODULE_CACHE=(1)

# Bottom line: VirtualEnv name (dynamic)
ZUNDER_PROMPT_BOTTOM_RIGHT_MODULES=('echo $VIRTUAL_ENV')
```

#### Performance Tracking

You can use the `prompt-timings` command to see a breakdown of how long each module takes to execute in milliseconds. This is useful for identifying slow commands that should be cached.

```text
zunder-prompt module timings (ms):

Top Right Modules:
  [0] date +%H:%M:%S                     1.23 ms
  [1] python --version                  45.67 ms (cached)

Bottom Right Modules:
  [0] echo $VIRTUAL_ENV                  0.45 ms
```

## Thanks to

- [romkatv](https://github.com/romkatv) for gitsatus.
- [Starship](https://starship.rs/) for inspiration.
