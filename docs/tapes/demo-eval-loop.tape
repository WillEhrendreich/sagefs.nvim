Output docs/demo-eval-loop.gif

Set Width 1200
Set Height 700
Set FontSize 13
Set Framerate 15
Set Padding 16
Set Theme "Catppuccin Mocha"
Set LoopOffset 0%

Hide
Type `nvim --cmd "set rtp+=." samples/eval-demo.fsx`
Enter
Sleep 3s
Show

Sleep 1s

# Evaluate the first cell
Escape
Type "gg"
Sleep 500ms
Alt+Enter
Sleep 2s

# Move to next cell and evaluate
Type "}j"
Sleep 500ms
Alt+Enter
Sleep 2s

# Move to last cell and evaluate
Type "}j"
Sleep 500ms
Alt+Enter
Sleep 3s
