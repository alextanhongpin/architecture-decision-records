# Version Tag

what strategy to use for version tag? 
- use commit hash of repo. Bad, it means for each deployment, there will be one inage associated with it. Need to rebuild
- use the md5 of the package lock, e.g. go.mod+go.sum+Dockerfile. Only rebuild if dependencies changed or Dockerfile changed. Deployment just require selecting base image plus source code to deploy
