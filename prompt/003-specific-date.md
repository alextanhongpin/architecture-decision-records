# Dates

Dates are one of the most common functionality when prompting.

How can we ask the model to produce the correct dates or date range?

- list down the holidays in Malaysia in year YEAR
- what date is today
- what date is 7 days ago (essentially one week)
- from when did i do sth
- what is my availability
- what time is it now in Australia

one simple way to achieve this is to just hardcode all the possible dates rather than doing function calling to parse them.



Events 
- once we have the dates, we can use them to plan events on calendar
- this requires a more complex system, typically a scheduling system
