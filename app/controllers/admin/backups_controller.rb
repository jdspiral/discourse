require_dependency "backup_restore"

class Admin::BackupsController < Admin::AdminController

  skip_before_filter :check_xhr, only: [:index, :show, :logs, :check_chunk, :upload_chunk]

  def index
    respond_to do |format|
      format.html do
        store_preloaded("backups", MultiJson.dump(serialize_data(Backup.all, BackupSerializer)))
        store_preloaded("operations_status", MultiJson.dump(BackupRestore.operations_status))
        store_preloaded("logs", MultiJson.dump(BackupRestore.logs))
        render "default/empty"
      end
      format.json do
        render_serialized(Backup.all, BackupSerializer)
      end
    end
  end

  def status
    render_json_dump(BackupRestore.operations_status)
  end

  def create
    BackupRestore.backup!(current_user.id, true)
  rescue BackupRestore::OperationRunningError
    render json: failed_json.merge(message: I18n.t("backup.operation_already_running"))
  else
    render json: success_json
  end

  def cancel
    BackupRestore.cancel!
  rescue BackupRestore::OperationRunningError
    render json: failed_json.merge(message: I18n.t("backup.operation_already_running"))
  else
    render json: success_json
  end

  # download
  def show
    filename = params.fetch(:id)
    if backup = Backup[filename]
      send_file backup.path
    else
      render nothing: true, status: 404
    end
  end

  def destroy
    filename = params.fetch(:id)
    Backup.remove(filename)
    render nothing: true
  end

  def logs
    store_preloaded("operations_status", MultiJson.dump(BackupRestore.operations_status))
    store_preloaded("logs", MultiJson.dump(BackupRestore.logs))
    render "default/empty"
  end

  def restore
    filename = params.fetch(:id)
    BackupRestore.restore!(current_user.id, filename, true)
  rescue BackupRestore::OperationRunningError
    render json: failed_json.merge(message: I18n.t("backup.operation_already_running"))
  else
    render json: success_json
  end

  def rollback
    BackupRestore.rollback!
  rescue BackupRestore::OperationRunningError
    render json: failed_json.merge(message: I18n.t("backup.operation_already_running"))
  else
    render json: success_json
  end

  def readonly
    enable = params.fetch(:enable).to_s == "true"
    enable ? Discourse.enable_readonly_mode : Discourse.disable_readonly_mode
    render nothing: true
  end

  def check_chunk
    identifier         = params.fetch(:resumableIdentifier)
    filename           = params.fetch(:resumableFilename)
    chunk_number       = params.fetch(:resumableChunkNumber)
    current_chunk_size = params.fetch(:resumableCurrentChunkSize).to_i

    # path to chunk file
    chunk = Backup.chunk_path(identifier, filename, chunk_number)
    # check whether the chunk has already been uploaded
    has_chunk_been_uploaded = File.exists?(chunk) && File.size(chunk) == current_chunk_size
    # 200 = exists, 404 = not uploaded yet
    status = has_chunk_been_uploaded ? 200 : 404

    render nothing: true, status: status
  end

  def upload_chunk
    filename = params.fetch(:resumableFilename)
    return render nothing:true, status: 415 unless filename.to_s.end_with?(".tar.gz")

    file               = params.fetch(:file)
    identifier         = params.fetch(:resumableIdentifier)
    chunk_number       = params.fetch(:resumableChunkNumber).to_i
    chunk_size         = params.fetch(:resumableChunkSize).to_i
    total_size         = params.fetch(:resumableTotalSize).to_i
    current_chunk_size = params.fetch(:resumableCurrentChunkSize).to_i

    # path to chunk file
    chunk = Backup.chunk_path(identifier, filename, chunk_number)
    dir = File.dirname(chunk)

    # ensure directory exists
    FileUtils.mkdir_p(dir) unless Dir.exists?(dir)
    # save chunk to the directory
    File.open(chunk, "wb") { |f| f.write(file.tempfile.read) }

    uploaded_file_size = chunk_number * chunk_size

    # when all chunks are uploaded
    if uploaded_file_size + current_chunk_size >= total_size
      # merge all the chunks in a background thread
      Jobs.enqueue(:backup_chunks_merger, filename: filename, identifier: identifier, chunks: chunk_number)
    end

    render nothing: true
  end

end
