include "root"    { path = find_in_parent_folders("root.hcl") }
include "catalog" { path = "${get_repo_root()}/_catalog/cluster/karpenter.hcl" }
