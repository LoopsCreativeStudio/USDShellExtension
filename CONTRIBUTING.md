# Contribution and Code of Conduct

## Contributing
Please note that we have a code of conduct. Kindly follow it in all your interactions with the project. When contributing to this repository, please first:
- Discuss the change you wish to make via a GitHub issue.
- Add the appropriate label(s) to the new issue.
- Any merge request that has not been discussed in an issue beforehand will not be considered.

## Workspace Setup

> [!NOTE]
> The project is built with PowerShell and MSBuild (Visual Studio 2026, v145 toolset, x64 only).

1. Clone the repository.
2. Extract the [NVIDIA USD 25.08 pre-built package](https://developer.nvidia.com/usd) to `D:\usd.py312.windows-x86_64.usdview.release-v25.08` (or update `$USD_SDK` in `build.ps1` if your path differs).
3. Build the project.
4. Install (requires Administrator).

*example*
```powershell
git clone https://github.com/LoopsCreativeStudio/USDShellExtension.git
cd USDShellExtension

# Build all projects (Release|x64)
.\build.ps1

# Install to C:\Program Files\UsdShellExtension\ and register COM servers
.\install.ps1

# To uninstall
.\install.ps1 -Uninstall
```

## Release Process
The **main** branch is the **primary** and default branch. Branches are continuously created from **main** to develop features, fix bugs, refactor, etc., then merged and squashed back into **main**.
Releases are tagged on **main**.


## Development Phases
Prior to a release, we will go through specific branches (fixes, features, etc.), then move into a **dev** phase. Merging new features is frozen and developers focus on bug fixes. New features can still be developed, but will need to wait until after the release tag to be merged into **main**.

### dev
**USDShellExtension** is tested by technical users *(e.g. developers, technical testers...)* to ensure nothing is broken and that it remains usable in all cases...

### main
**USDShellExtension** is tested by daily users *(e.g. artists, supervisors, reviewers...)* to ensure everything works and that new features are as polished as possible.

### roadmap
We are a small studio with a small development team. We do not use milestones at this time.


## Pull Request Process
1. Fork the repository.
2. Create a new branch from **main** with a descriptive name reflecting its content. **Keep one branch per feature, otherwise you will be asked to split it.** It is preferable to start a branch from the issue board.
3. Code, **test**, make sure everything works and nothing is broken. You can make as many commits as needed, they will be squashed at the end. Make sure to strictly follow the **coding style**.
4. Update the documentation if necessary.
5. Write your tests if the feature allows for it (don't hesitate to ask for help).
6. Rebase your branch on **main** before considering your work done.
7. Create a pull request targeting **main**. **Your git history must be clean.**
8. Apply fixes from reviews until they are considered complete. It may happen that the **main** branch evolves during the review process and creates conflicts with your branch; you will then be asked to rebase your branch.
9. Be happy, your contribution has been merged! (thank you)
10. Wait for the next release to be tagged to see everyone using your wonderful work.


## Tests
The development of **USDShellExtension** is very demanding in terms of stability. This is why manually testing your contribution and running non-regression tests is non-negotiable. Be aware that you may be asked to write associated automated tests when proposing a feature, otherwise it might not be approved for merging into the core project. *"But that takes time!"* Yes, and it saves everyone much more: a bug represents an enormous time cost at scale, for users and for core team members alike. Spending a little extra time writing tests as a single contributor will make life easier for everyone.

> [!NOTE]
> If you are fixing a bug, writing associated tests to ensure the bug will not reoccur is appreciated, but not mandatory.

### Manually
The core of **USDShellExtension** focuses on staying simple and having distinct processes as much as possible. Randomly test your feature, try running something completely different during its process, play with it until you break it! If you despair of making it crash, your feature is ready to be submitted to the review process...


## Naming Conventions

### Branch
A clear and concise name with a short prefix to indicate the issue number, then the type of change:
We follow [Semantic Versioning](https://semver.org) and use fully automated version management and releases based on [release-please](https://github.com/googleapis/release-please).

### Commit Message Header

[Commit message guidelines](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md)

```
<type>(<scope>): <short summary>
   │      |             │
   │      |             └─⫸ Summary in present tense. Not capitalized. No period at the end.
   │      |
   |      └─⫸ Commit Scope: preview|thumbnail|properties|context-menu|installer|resolver|build|ci|docs|...
   |
   └─⫸ Commit Type: build|chore|ci|docs|feat|fix|perf|refactor|style|test
```

The **type** and **short summary** fields are mandatory.


### Type
Must be one of the following:
- **build**: Changes that affect the build system or external dependencies
- **chore**: Other changes that do not modify src or test files
- **ci**: Changes to CI configuration files and scripts
- **docs**: Documentation only changes
- **feat**: A new feature
- **fix**: A bug fix
- **perf**: A code change that improves performance
- **refactor**: A code change that neither fixes a bug nor adds a feature
- **revert**: Reverts a previous commit
- **style**: Changes that do not affect the meaning of the code
- **test**: Adding missing tests or correcting existing tests

**Breaking Change Indicator**
Breaking changes must be indicated by a ``!`` before the ``:`` in the subject line, e.g. ``feat!: remove status endpoint``
- This is an optional part of the format


### Commit
The commit message must start with the **type**, followed by a colon, then the type of changes made, followed by a short description of the change. A longer description can be added on the second line.

### Examples
**fix:** Short description for the fix
**feat:** Short description for the feature
**feat!:** remove ticket list endpoint
**perf:** reduce memory footprint...
**style:** remove blank line
**refactor:** implement Fibonacci number calculation recursively
**build:** update dependencies


## Coding Style

### Comment your code!
The code of **USDShellExtension** must be commented, and contributing to **USDShellExtension** means adopting this habit. The overall algorithm should be understandable by reading the comments alone.

> [!IMPORTANT]
> - Comments must be in **English.**
> - Docstrings must be in **English.**
> - Commits must be in **English.**
> - Documentation must be written in **English.**

### Explicit variable names
We prefer a long and explicit variable name over a short and obscure one.
- Check the conventions of your language.
- **timeline_item_path** is perfect, whereas **tip** or **tlitmpt** are unacceptable.
- A shortened name is still acceptable as long as it is perfectly obvious: **items_dir**.

### Docstrings in less common languages
Some languages do not follow Python's docstring philosophy. They mainly use headers or even silent comments.
Make sure to refer to your language and follow its conventions.

#### Bash

[Bash language guide](https://google.github.io/styleguide/shellguide.html)

Don't forget the shebang header `#!`

```bash
#!/bin/sh -x
#!/bin/bash
#!/usr/bin/env bash
```

Add header description.
```bash
############################################################################################
#Script Name        : name
#Description        : 
#       Add description.
#
#Installation       :
#       Explain how execute.
#       `bash -c "$(wget -qLO - https://github.com/LoopsCreativeStudio/USDShellExtension/script.sh)"`
#
#Author             : LoopsCreativeStudio
#Email              : tech@loopscreativestudio.com
#Note               : bash ./name.sh
#Version            : 1.0.0
############################################################################################
```

Use `#` to explain, even above a function.
```bash
#######################################
# Delete a file in a sophisticated manner.
# Arguments:
#   File to delete, a path.
# Returns:
#   0 if thing was deleted, non-zero on error.
#######################################
function del_thing() {
  rm "$1"
}
```

For long scripts, modularize and source redundant functions in another file with the `.func` extension.


#### Powershell

[Powershell language guide](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/documentation-and-comments)

Add a header description.
```powershell
<#
  .SYNOPSIS
  Add description.

  .DESCRIPTION
  Explain how execute, how it work, what does.

  .PARAMETER one
  Explain first params.

  .PARAMETER two
  Explain second params.

  .NOTES
    Author:         Loops Creative Studio
    Creation Date:  2026/05/22
    Version:        1.0.0

  .EXAMPLE
  PS> .\my_script.ps1

  .LINK
  https://github.com/LoopsCreativeStudio/USDShellExtension
#>
```

Use `<#` `#>` to explain, even below a function.
```powershell
function CreateADUser {
    <#
        Find if user already exist on ActiveDirectory before creation.
    #>
    if (Get-ADUser -Filter {SamAccountName -eq $FormatLogin}){
        Write-Warning "User $FormatLogin already exists in Active Directory."
        ...
    }
}
```

#### Javascript

[Javascript language guide](https://javascript.info/comments)

Add a header description.

```javascript
/**
 * my_script.js
 * add description...
 *
 * 
 * @summary add short desc.
 * @license MIT, https://opensource.org/license/mit
 * @version 1.0.0
 * @author  loopscreativestudio, https://loopscreativestudio.com/
 * @updated 2026-05-22
 * @link    https://github.com/LoopsCreativeStudio/USDShellExtension
 *
 * 
 */
```

Use `/*` `*/` to explain, even above a function.
```javascript
/**
 * Returns x raised to the n-th power.
 *
 * @param {number} x The number to raise.
 * @param {number} n The power, must be a natural number.
 * @return {number} x raised to the n-th power.
 */
function pow(x, n) {
  ...
}
```

### Docstrings

> [!IMPORTANT]
> [Google Style Python Docstrings](https://sphinxcontrib-napoleon.readthedocs.io/en/latest/example_google.html).
> [Python language guide](https://google.github.io/styleguide/pyguide.html)

##### Single-line docstring

```python
"""Do this action"""
```

- Rules:
   - Use `"""` and not `'''`
   - No space before the first letter
   - No space after the last letter
   - No period at the end of the line
   - Use the imperative mood


##### Multi-line docstring

```python
"""Do this action
To make the world a better place.
"""
```

- Rules:
   - Use `"""` and not `'''`
   - No space before the first letter
   - The closing `"""` must be on its own line
   - No period at the end of the first line
   - Use the imperative mood on the first line
   - Only one sentence on the first line
   - Add a blank line between the first line and the following ones

#### Parameters and return


```python
def module_level_function(param1, param2=None, *args, **kwargs):
    """This is an example of a module level function.

    Function parameters should be documented in the ``Args`` section. The name
    of each parameter is required. The type and description of each parameter
    is optional, but should be included if not obvious.

    If *args or **kwargs are accepted,
    they should be listed as ``*args`` and ``**kwargs``.

    The format for a parameter is::

        name (type): description
            The description may span multiple lines. Following
            lines should be indented. The "(type)" is optional.

            Multiple paragraphs are supported in parameter
            descriptions.

    Args:
        param1 (int): The first parameter.
        param2 (:obj:`str`, optional): The second parameter. Defaults to None.
            Second line of description should be indented.
        *args: Variable length argument list.
        **kwargs: Arbitrary keyword arguments.

    Returns:
        bool: True if successful, False otherwise.

        The return type is optional and may be specified at the beginning of
        the ``Returns`` section followed by a colon.

        The ``Returns`` section may span multiple lines and paragraphs.
        Following lines should be indented to match the first line.

        The ``Returns`` section supports any reStructuredText formatting,
        including literal blocks::

            {
                'param1': param1,
                'param2': param2
            }

    Raises:
        AttributeError: The ``Raises`` section is a list of all exceptions
            that are relevant to the interface.
        ValueError: If `param2` is equal to `param1`.

    """
    if param1 == param2:
        raise ValueError('param1 may not be equal to param2')
    return True
```

### Import statement order

1. Python standard library (sys, os...)
2. Third-party libraries (OTIO, PySide2, Blender)
3. Your internal modules

##### Order

They must be sorted in alphabetical order.

```python
# Wrong
import sys
import os
import unittest

# Right
import os
import sys
import unittest
```

##### Code Formatting and Linter

[Ruff](https://github.com/astral-sh/ruff) is used with default conventions.

### Code of Conduct

#### Our Pledge

In the interest of fostering an open and welcoming environment, we, as contributors and maintainers, pledge to make participation in our project and our community a harassment-free experience for everyone, regardless of age, body size, disability, ethnicity, gender identity and expression, level of experience, nationality, personal appearance, race, religion, or sexual identity and orientation.

#### Our Standards

Examples of behavior that contributes to creating a positive environment include:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

Examples of unacceptable behavior by participants include:

- The use of sexualized language or imagery, and unwelcome sexual attention or advances
- Trolling, insulting or derogatory comments, and personal or political attacks
- Public or private harassment
- Publishing others' private information, such as a physical or electronic address, without explicit permission
- Any other conduct which could reasonably be considered inappropriate in a professional setting

#### Our Responsibilities

Project maintainers are responsible for clarifying the standards of acceptable behavior and are expected to take appropriate and fair corrective action in response to any instances of unacceptable behavior.
Project maintainers have the right and responsibility to remove, edit, or reject comments, commits, code, wiki edits, issues, and other contributions that are not aligned with this Code of Conduct, or to ban temporarily or permanently any contributor for other behaviors that they deem inappropriate, threatening, offensive, or harmful.

#### Scope

This Code of Conduct applies both within project spaces and communication utilities, and in public spaces when an individual is representing the project or its community. Examples of representing a project or community include using an official project email address, posting via an official social media account, or acting as a designated representative at an online or offline event. Representation of a project may be further defined and clarified by the project maintainers.

#### Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may be reported by contacting the project team. All complaints will be reviewed and investigated and will result in a response that is deemed necessary and appropriate to the circumstances. The project team is obligated to maintain confidentiality with regard to the reporter of an incident. Further details of specific enforcement policies may be posted separately.
Project maintainers who do not follow or enforce the Code of Conduct in good faith may face temporary or permanent repercussions as determined by other members of the project's leadership.

#### Attribution

This Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org), version 1.4, available at [http://contributor-covenant.org/version/1/4](http://contributor-covenant.org/version/1/4).
