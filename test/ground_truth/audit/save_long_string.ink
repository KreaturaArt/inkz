// Audit: strings longer than 2048 bytes must survive save and load (the old runtime truncates).
VAR long = ""
VAR count = 0
- (grow)
~ long = "{long}0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
~ count++
{ count < 25: -> grow }
* [Show]
    {long}
    -> END
