# Refresh through a resident agent

A lightweight process launched with the user session will poll configured provider accounts at the selected interval and persist normalized snapshots for the app and widget. WidgetKit reloads remain best-effort under the system refresh budget, while reset countdowns derive locally from timestamps and every surface reports snapshot age rather than implying minute-level widget reload guarantees.
