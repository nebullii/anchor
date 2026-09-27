# Encrypts existing plaintext projects.webhook_secret values in place now that
# Project declares `encrypts :webhook_secret`.
class EncryptProjectWebhookSecrets < ActiveRecord::Migration[8.1]
  class MigrationProject < ActiveRecord::Base
    self.table_name = "projects"
    encrypts :webhook_secret
  end

  def up
    select_rows("SELECT id, webhook_secret FROM projects WHERE webhook_secret IS NOT NULL").each do |id, plaintext|
      next if plaintext.to_s.start_with?("{\"p\":")  # already an encrypted payload

      # Serialize straight to ciphertext: assigning through the model would
      # try to decrypt the old plaintext value for dirty tracking and raise.
      ciphertext = MigrationProject.type_for_attribute("webhook_secret").serialize(plaintext)
      MigrationProject.where(id: id).update_all(webhook_secret: Arel::Nodes::Quoted.new(ciphertext))
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
