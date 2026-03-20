# Auto Voice Lines Edit and Naming

## Settup
- Install with DM_Reapertoolkit
- Install fuzzywuzzy
install by running this in the comand prompt:
C:\your\python\executable\path\python.exe -m pip install fuzzywuzzy
Find your pyton path in reaper->Options->Preferences->Reascript-> custom path to python dll directory
- Settup Azure Speech-to-Text

## How to use
1. Prepare a CSV script with:
    - Line text
    - Line ID
    - (Optional) Character
2. prepare recording on one track (multiple takes OK)
3. Use Dynamic Split → roughly 1 item per line
4. Use Reposition items → add spacing (e.g. 5s)
5. Select all items → run the script
6. Set:
    - Fill CSV path
    - Fill CSV Headers
    - Language Code (e.g. en-US)
7. Press Detect takes from CSV

## Result
- Regions created per line ID
- Takes grouped automatically


