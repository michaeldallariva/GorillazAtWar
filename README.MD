# GorillazAtWar - Graphical Edition

A two player artillery game written entirely in PowerShell 7, using Windows Forms and GDI+ for graphics. Two gorillas stand on top of randomly generated buildings and take turns lobbing an exploding banana at each other, adjusting angle and power while accounting for wind.

## Historical Reference

This project is based on the general concept of the original QBasic Gorillas game, which shipped as a sample program with MS-DOS 5.0 and QBasic around 1991. The exact original authorship is unclear. Some sources credit IBM, others credit Microsoft, and the information available online is conflicting, so no definitive original author credit can be given here.

No original QBasic source code is included or reproduced in this project. This is an independent, from scratch reimplementation written in PowerShell, using modern tooling and an entirely new graphical renderer.

## Features

- Real vector graphics rendered with GDI+, not console text characters
- Procedurally generated skyline with randomized building heights, colors and lit windows
- Physics based banana trajectory affected by gravity, wind and player input
- Craters that visually and physically carve into buildings on impact
- Adjustable Explosion Power (Normal, Big, Nuke)
- Adjustable Game Speed (50 percent faster, 100 percent faster, 200 percent faster)
- Optional CPU opponent with simple adaptive aim
- Sound effects with an on and off toggle
- Speech bubble taunts and a victory dance and defeat animation at the end of each round
- Drifting clouds and a day and night toggle with a sun or a full moon
- About dialog with author information and license text

## Requirements

- Windows
- PowerShell 7.0 or later (pwsh)
- .NET Windows Forms support (included with Windows)

This game uses Windows Forms, so it will only run on Windows.

## How to Run

1. Download `gorillas.ps1`
2. Open a terminal and run:

   ```
   pwsh -File .\gorillas.ps1
   ```

The script requires a single threaded apartment (STA) thread for Windows Forms. If it is not already running on one, it will automatically relaunch itself with the correct flag.

## Controls

- Set Angle (0 to 90 degrees) and Power (1 to 100) for each player
- Click THROW to launch the banana
- Toggle CPU Opponent to let the computer play Player 2
- Adjust Explosion Power and Game Speed with the sliders
- Use the speaker icon to mute or unmute sound
- Use the sun or moon icon to switch between day and night
- Click New Game to reset the score and generate a new skyline

## License

This project is released under the MIT License, a permissive open source license. You are free to use, copy, modify, merge, publish, distribute, sublicense and sell copies of this software, provided the copyright notice and license text are included in all copies or substantial portions of the software.

```
MIT License

Copyright (c) 2026 [Your Name]

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Replace `[Your Name]` and the copyright year with your own details before publishing.

## Disclaimer

This is a fan made, independent project created for educational and entertainment purposes. It is not affiliated with, endorsed by, or connected to IBM or Microsoft. All trademarks belong to their respective owners.


<img width="1178" height="940" alt="Image" src="https://github.com/user-attachments/assets/653bef36-ccc2-4c23-a074-32aff0f0ae9f" />
<img width="1171" height="945" alt="Image" src="https://github.com/user-attachments/assets/8e2dd3cd-1da2-41e2-a7e6-ecc0d02de174" />
