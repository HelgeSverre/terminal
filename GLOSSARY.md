# Terminal

The terminal presents an interactive program's output and translates user actions into that program's input. These terms distinguish the program, its terminal state, and the presentation of that state.

## Language

**Session**:
A running program's connection to a terminal, from launch through output drainage and process exit.
_Avoid_: Core, shell (the program need not be a shell)

**Terminal emulator**:
The interpreter of terminal output and input protocols, including their effects on displayed content and terminal modes.
_Avoid_: Core, engine

**Pane**:
One terminal presentation within a window, with its own session, focus, and selection.
_Avoid_: Session (when referring to window layout)

**Screen**:
A rectangular grid of cells and its cursor state. A terminal has a primary screen and an alternate screen.
_Avoid_: Viewport, document

**Terminal document**:
The terminal's retained content: primary history, primary screen, and alternate screen, together with their content identities.
_Avoid_: Screen (when including history)

**History**:
Retained rows that have scrolled off the primary screen. The alternate screen has no history.
_Avoid_: Buffer (without naming which content it contains)

**Viewport**:
The portion of terminal content currently shown, either following live output or anchored to retained primary content.
_Avoid_: Screen, scroll offset (an offset describes a resolved position)

**Physical row**:
One grid-width row of cells. A soft wrap connects it to the next physical row without introducing a line break.
_Avoid_: Line (when width and wrap position matter)

**Logical line**:
Content connected by soft wraps, ending at an explicit line break or the end of the retained content.
_Avoid_: Row

**Cell**:
One grid position, containing a grapheme lead, its wide-cell continuation, a wrap spacer, or blank content, together with presentation attributes.
_Avoid_: Character (a character need not occupy one cell)

**Snapshot**:
A consistent, immutable view of terminal content and presentation state at one revision.
_Avoid_: Frame (a frame is a rendered presentation)

**Image resource**:
Decoded image content identified independently of where it is displayed.
_Avoid_: Placement, texture (a rendering representation)

**Image placement**:
One occurrence of an image resource positioned in terminal content, with crop, extent, and stacking order.
_Avoid_: Image resource
