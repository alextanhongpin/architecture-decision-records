# Agent (or actor) pattern

instead of structuring using clean architecture, we define tools and agents.

agents is just a synonym for actor. agents execute in workspace (environment).

So for example, instead of writing code the way we interact with infrastructure (playwright etc), we desing actors that have access to tools (db, playwright).

The actors use the tools to carry out tasks from commands and return the result in report format.


```
function scrapeWebsite(options) {
  agent = new CrawlAgent(options)
  agent()
}

class CrawlAgent:
  def call():
    open browser
    call BrowserAgent(browser)
```

Agents can be nested if there are additional tooling.

we use ticker symbols to decide on the app name.

