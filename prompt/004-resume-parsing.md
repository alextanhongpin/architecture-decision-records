# Resume Parsing 

I tried creating a simple resume parser, but due to the unstructured nature of the document, just parsing and dumping the content into an LLM doesn't produce good result.
- it couldn't even tell the name of the candidate
- information like dates is hard to parse
- some information are not chunked together correctly, e.g. working experience and duration of work
- long resumes doesnt fit into the context window of smaller llms, so it requires additional chucking, leading to more context loss
- tried Donut transformer (document understanding transformer) but it doesn't seem to be able to answer questions from a resume as opposed to an invoice


How can we improve the parsing?
- dump the content and try to extract the NER?
