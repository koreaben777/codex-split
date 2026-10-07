# Shared Swift library sources: every file except executable entry points and the GUI.
SWIFT_LIBRARY=$(ls Sources/*.swift | grep -v -e '/main\.swift$' -e '/Launcher\.swift$' -e '/WorkDailyUI\.swift$' | tr '\n' ' ')
