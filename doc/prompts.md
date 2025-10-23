# Prompts that were useful and may be again

## update tooling

```text
/do use the ../js project as inspiration, and be sure the project has tooling implemented similarly:  
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

## update our own instructions

```text
/do our ~/.claude instructions grow over time, and sometimes there is redundancy.  In addition, models grow in capability, and we want to be sure we are providing the optimal instruction set to achieve our goals.  We don't want to be overly prescriptive.

Research the best practices for using claude code as of this month, October 2025.  Do a comprehensive review of our files.  Ask any questions needed.  Suggest any changes you think might be useful.
```

```text
/do research the new capabilities of claude skills.  Do a comprehensive review of this repository (which is my user level .claude) and consider of any commands, standards, or agents should be changed in this regard.
```
