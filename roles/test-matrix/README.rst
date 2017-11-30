Set the a enabled_services fact based based on the test matrix

**Role Variables**

.. zuul:rolevar:: test_matrix_features
   :default: files/features.yaml

   The YAML file that defines the test matrix.

.. zuul:rolevar:: test_matrix_branch
   :default: {{ zuul.override_checkout | default(zuul.branch) }}

   The git branch for which to calculate the test matrix.

.. zuul:rolevar:: test_matrix_role
   :default: primary

   The role of the node for which the test matrix is calculated.
   Valid values are 'primary' and 'subnode'.

 .. zuul:rolevar:: test_matrix_configs
    :default: []
    :type: list

   Feature configuration for the test matrix. This option allows enabling
   more features, as defined in ``test_matrix_features``.
   The default value is an empty list, however 'neutron' is added by default
   from stable/ocata onwards.
