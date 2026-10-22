# upgrade-keeps-knowledge-base

Proves: a first install scaffolds the knowledge base as before; an install over an existing project (a pipeline already there, or a knowledge base already written) never writes the knowledge base, creating none, and says how to scaffold by hand; acp doctor writes nothing in the project, its lifecycle probe running in a scratch copy of the configuration (a hard-coded PROJECT_ROOT included) still failing a layout the drivers cannot complete, and writing nothing outside its scratch folder even when CODE_DIR would lead out of it.
