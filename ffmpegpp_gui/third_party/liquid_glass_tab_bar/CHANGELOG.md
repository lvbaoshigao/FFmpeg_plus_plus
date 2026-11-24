## 0.1.0-dev.10

- While it moves, the glass droplet is never shorter than the bar (fast
  movement used to flatten it below the bar's height).
- A fast drag stretches the droplet a little less (0.45 → 0.36).

## 0.1.0-dev.9

- The held droplet is less tall: it grew with the taller capsule of dev.6
  and stuck out of the bar too far.

## 0.1.0-dev.8

- Light mode: the bar glass is a little whiter, so colourful content behind
  it is tinted like on iOS 26 instead of darker and more saturated.
- Dark mode: the bar dims colourful content behind it like iOS 26 (it used to
  glow).
- Dark mode: the resting capsule no longer washes out colourful content
  behind it, so the selected item stays readable.
- Tapping a far tab stretches the capsule less on the way (65% of the
  previous stretch).

## 0.1.0-dev.7

- The resting capsule is as wide as on iOS 26: it reaches 6 past its item on
  each side (was 4) and the items move inwards to make room. New style option
  `capsuleOverhang`.

## 0.1.0-dev.6

- Long jumps between tabs are slower still (380 ms + 160 ms per extra tab).
- Default bar height matches the native iOS 26 tab bar (capsuleHeight
  51 → 54).
- Dark mode: unselected icons and labels are near-white (was gray), like
  iOS 26.

## 0.1.0-dev.5

- Pressing another tab slides the droplet there right away; the selection
  only changes when the finger is lifted over it (like iOS 26). Sliding the
  finger off the bar cancels and the droplet returns.
- Longer jumps between tabs animate a bit slower (380 ms + 60 ms per extra
  tab).
- CI pinned to Flutter 3.44.8.

## 0.1.0-dev.4

- The droplet keeps its full size while the finger is down; it no longer
  shrinks when the finger stops moving (only the speed stretch eases out).

## 0.1.0-dev.3

- Droplet screenshots (press-and-hold, light and dark).
- CI workflow (format, analyze, test, publish dry run).

## 0.1.0-dev.2

- Shorter package description; more search topics.
- Example: darker cards in dark mode, label toggle.
- Demo video and new screenshots (light/dark, with and without labels).

## 0.1.0-dev.1

- Initial release: floating liquid glass tab bar with a refracting droplet
  selection, drag to select, action items, icon-only items, light and dark
  mode.
