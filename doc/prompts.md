# Prompts that were useful and may be again

## update tooling

```sh
/plan-execution use the ../js project as inspiration, and be sure the project has tooling implemented similarly:  
 - Create a git branch called tooling
 - Remove eslint and prettier from this project, replace with biome and markdownlint
 - Update the .vscode settings changes  
 - Remove the typescript project references and implement the similar check-types.  
 - Add the check-circular, and change the script names here to be consistent with the ones from the ../js project.  
 - Update all script names with ':" in them, e.g. clean:yarn -> clean-yarn
 - Migrate any uses of tsup to tsdown
 - Migrate any uses of vite for library builds (as indicated by the build script, or evidence of vite.config.lib.ts) to tsdown
 - Verify in the end after all is done with a call to yarn check, which should be like the one in ../js.  
 - Once complete, update the CLAUDE.md with any changes.
 - Create a git commit
 - Push a PR to github
```
