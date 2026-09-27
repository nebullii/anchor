# Phase 1 of moving Secret#value from attr_encrypted (AES-256-CBC, no MAC)
# to Active Record Encryption (AES-256-GCM, authenticated, key rotation).
#
# `value` holds the new AR-encrypted ciphertext. The legacy columns become
# nullable so that, once every row is re-encrypted (Secret.reencrypt_legacy!)
# and legacy dual-writes are switched off, they can be cleared and dropped.
class AddArEncryptedValueToSecrets < ActiveRecord::Migration[8.1]
  def change
    add_column :secrets, :value, :text
    change_column_null :secrets, :encrypted_value,    true
    change_column_null :secrets, :encrypted_value_iv, true
  end
end
