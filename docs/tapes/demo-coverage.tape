Output docs/demo-coverage.gif

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

# Evaluate all cells so coverage data is populated
Escape
Type "gg"
Sleep 300ms
Alt+Enter
Sleep 2s
Type "}j"
Alt+Enter
Sleep 2s
Type "}j"
Alt+Enter
Sleep 3s

# Show coverage summary
Type ":SageFsCoverage"
Enter
Sleep 3s
