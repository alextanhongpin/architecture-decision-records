Clean architecture 
- create using forms, can have a service to populate data
- other data should use service or entity
- repository should not have types, this is to prevent importing from repo, instead repo should implement entity
- CreateUserForm
- business logic should belong in entity, if there are multiple, then place it in service
- each use case should chain multiple domain logic, or service
- should service have side effects? Some logic may be reused
- find etc should query the original to be updated, or just a command to be executed which is more eprformant since we don't have to query the original


RagIndex(Source)
Source.Validate()
Service.ResolveSource()
  Source.isRemote() then download
  Source.isLocal() then read
CleanSource(data)
ChunkSource(data)
EmbedSource(data)
Save(chunk)


Dealing with polymorphism (or switch)

Source interface {
  Clean()
  Chunk()
  Embed()
}

CleanSource(interface Clean()) 

Type htmlSource {
  Data []byte
}


Func(s) Clean() {

}
Func (s) Chunk() {

}

