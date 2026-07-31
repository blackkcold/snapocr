import Foundation

/// 统一错误类型
///
/// 覆盖应用各模块可能产生的错误，提供中文错误描述和恢复建议。
/// 所有错误都符合 `LocalizedError` 协议，可用于 UI 层展示。
public enum AppError: LocalizedError, Sendable {
    // MARK: - 通用错误

    /// 功能尚未实现
    case notImplemented(feature: String)
    /// 无效的参数
    case invalidArgument(_ message: String)
    /// 内部未知错误
    case internalError(_ message: String)

    // MARK: - 截图错误

    /// 截图权限被拒绝
    case capturePermissionDenied
    /// 截图操作失败
    case captureFailed(reason: String)
    /// 屏幕不可用（如未检测到显示器）
    case screenNotAvailable

    // MARK: - OCR 错误

    /// OCR 引擎不可用
    case ocrEngineUnavailable
    /// OCR 识别失败
    case ocrRecognitionFailed(reason: String)
    /// 识别结果置信度过低
    case ocrConfidenceTooLow(confidence: Float)

    // MARK: - 条码错误

    /// 未检测到条码
    case barcodeNotFound
    /// 不支持的条码类型
    case barcodeInvalidType(_ type: String)

    // MARK: - 安全错误

    /// 数据加密失败
    case encryptionFailed(reason: String)
    /// 数据解密失败
    case decryptionFailed(reason: String)

    // MARK: - 历史错误

    /// 历史存储空间已满
    case historyStorageFull
    /// 指定的历史条目不存在
    case historyEntryNotFound(id: String)

    // MARK: - 自动化错误

    /// CLI 命令无效
    case cliInvalidCommand(_ command: String)
    /// URL Scheme 无效
    case urlSchemeInvalid(url: String)

    // MARK: - 滚动截图错误

    /// 滚动截图拼接失败
    case scrollStitchFailed(reason: String)
    /// 未找到可滚动窗口
    case scrollWindowNotFound
    /// 检测到重复的拼接帧
    case scrollFrameDuplicate

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let feature):
            return "\(feature) 尚未实现"
        case .invalidArgument(let message):
            return "无效参数: \(message)"
        case .internalError(let message):
            return "内部错误: \(message)"
        case .capturePermissionDenied:
            return "截图权限被拒绝"
        case .captureFailed(let reason):
            return "截图失败: \(reason)"
        case .screenNotAvailable:
            return "屏幕不可用"
        case .ocrEngineUnavailable:
            return "OCR 引擎不可用"
        case .ocrRecognitionFailed(let reason):
            return "OCR 识别失败: \(reason)"
        case .ocrConfidenceTooLow(let confidence):
            return "OCR 置信度过低: \(confidence)"
        case .barcodeNotFound:
            return "未找到条码"
        case .barcodeInvalidType(let type):
            return "不支持的条码类型: \(type)"
        case .encryptionFailed(let reason):
            return "加密失败: \(reason)"
        case .decryptionFailed(let reason):
            return "解密失败: \(reason)"
        case .historyStorageFull:
            return "历史存储已满"
        case .historyEntryNotFound(let id):
            return "历史条目不存在: \(id)"
        case .cliInvalidCommand(let command):
            return "无效命令: \(command)"
        case .urlSchemeInvalid(let url):
            return "无效 URL Scheme: \(url)"
        case .scrollStitchFailed(let reason):
            return "滚动拼接失败: \(reason)"
        case .scrollWindowNotFound:
            return "未找到可滚动窗口"
        case .scrollFrameDuplicate:
            return "检测到重复帧"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notImplemented:
            return "请等待后续版本更新"
        case .invalidArgument:
            return "请检查输入参数后重试"
        case .internalError:
            return "请尝试重启应用，如果问题持续请联系开发者"
        case .capturePermissionDenied:
            return "请在「系统设置 > 隐私与安全性 > 屏幕录制」中授予 SnapGlass 权限"
        case .captureFailed:
            return "请检查屏幕状态后重试"
        case .screenNotAvailable:
            return "请确保显示器已连接并处于活动状态"
        case .ocrEngineUnavailable:
            return "请确保系统版本满足最低要求（macOS 13+）"
        case .ocrRecognitionFailed:
            return "请确保图片中包含清晰可辨识的文本"
        case .ocrConfidenceTooLow:
            return "请尝试提供更高分辨率或更清晰的图片"
        case .barcodeNotFound:
            return "请确保图片中包含清晰完整的条码"
        case .barcodeInvalidType:
            return "目前仅支持 QR Code、Code 128、EAN-13 等常见条码类型"
        case .encryptionFailed:
            return "加密过程出现异常，请重试"
        case .decryptionFailed:
            return "解密失败，数据可能已损坏或密钥不匹配"
        case .historyStorageFull:
            return "请清理部分历史记录后重试"
        case .historyEntryNotFound:
            return "该条目可能已被删除或已过期"
        case .cliInvalidCommand:
            return "请使用 --help 查看可用命令列表"
        case .urlSchemeInvalid:
            return "请检查 URL 格式是否正确"
        case .scrollStitchFailed:
            return "请尝试重新选择滚动区域，或使用普通截图模式"
        case .scrollWindowNotFound:
            return "请将鼠标悬停在目标窗口上后重试"
        case .scrollFrameDuplicate:
            return "滚动速度可能过快，请尝试降低滚动速度"
        }
    }
}
