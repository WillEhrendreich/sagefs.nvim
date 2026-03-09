Output docs/screenshot-03-live-testing.png

Set Width 1200
Set Height 700
Set FontSize 13
Set Framerate 15
Set Padding 16
Set Theme "Catppuccin Mocha"

Hide
Type "nvim --cmd \"set rtp+=.\" samples/eval-demo.fsx"
Enter
Sleep 3s
Show

Type "\<Esc>gg"
Sleep 500ms
Type "\<A-CR>"
Sleep 2s
Type "}j\<A-CR>"
Sleep 2s
Type "}j\<A-CR>"
Sleep 2s
Type ":SageFsTestPanel\<CR>"
Sleep 2s
