# frozen_string_literal: true

# Passthrough type for jsonb_accessor fields that hold unstructured JSON
# (arrays of hashes, plain hashes). ActiveModel::Type::Value casts nothing,
# so Ruby Arrays/Hashes round-trip unchanged through the typed accessor.
ActiveRecord::Type.register(:value, ActiveModel::Type::Value)
