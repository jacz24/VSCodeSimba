/**
 * Simba Language Support for Visual Studio Code
 *
 * This extension provides language support for Simba scripts (.simba files),
 * including syntax highlighting, autocompletion, go-to-definition, and more.
 */

import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { ChildProcess, spawn } from 'child_process';
import {
    workspace,
    ExtensionContext,
    window,
    commands,
    OutputChannel,
    WebviewPanel,
    ViewColumn,
    Uri,
    StatusBarItem,
    StatusBarAlignment,
    ThemeColor,
    Task,
    TaskDefinition,
    TaskGroup,
    TaskProvider,
    TaskScope,
    ShellExecution,
    tasks
} from 'vscode';

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    Executable,
    State
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: OutputChannel;
let scriptOutputChannel: OutputChannel;
let runningScript: ChildProcess | undefined;
let selectedTargetWindow: WindowInfo | undefined;
let extensionContext: ExtensionContext | undefined;
let lspStatusBar: StatusBarItem;
let scriptStatusBar: StatusBarItem;
let targetStatusBar: StatusBarItem;
let scriptStartTime: number | undefined;
let scriptTimerInterval: ReturnType<typeof setInterval> | undefined;

/**
 * Check if verbose/debug logging is enabled for script output
 */
function isVerboseEnabled(): boolean {
    return workspace.getConfiguration('simba').get<string>('lsp.trace.server', 'off') === 'verbose';
}

/**
 * Log debug message to script output (only when verbose is enabled)
 */
function logDebug(message: string): void {
    if (isVerboseEnabled() && scriptOutputChannel) {
        scriptOutputChannel.appendLine(`[DEBUG] ${message}`);
    }
}

/**
 * Strip Simba debug flags from output lines
 * Simba prepends "\0\0XXXXXX" (2 null bytes + 6 hex chars) to lines with debug flags
 * After going through text streams, nulls may appear as spaces or other whitespace
 */
function stripSimbaDebugFlags(line: string): string {
    // Pattern: 2 control chars/spaces/nulls + 6 hex chars at start
    // Match: any 2 chars that are space/null/control, then 6 hex
    const match = line.match(/^[\x00-\x20]{0,2}([0-9A-Fa-f]{6})(.*)$/);
    if (match) {
        return match[2];
    }
    // Also try: starts with spaces then hex
    const match2 = line.match(/^\s*([0-9A-Fa-f]{6})(.+)$/);
    if (match2 && match2[1] && match2[2]) {
        return match2[2];
    }
    return line;
}

/**
 * Information about a window
 */
interface WindowInfo {
    handle: string;
    title: string;
    processName: string;
    pid: number;
}

/**
 * Debug Image Panel - WebView for displaying Simba debug images
 */
class DebugImagePanel {
    private static instance: DebugImagePanel | undefined;
    private panel: WebviewPanel | undefined;
    private maxWidth: number = 0;
    private maxHeight: number = 0;
    private currentWidth: number = 0;
    private currentHeight: number = 0;

    private constructor() {}

    static getInstance(): DebugImagePanel {
        if (!DebugImagePanel.instance) {
            DebugImagePanel.instance = new DebugImagePanel();
        }
        return DebugImagePanel.instance;
    }

    /**
     * Set maximum image size
     */
    setMaxSize(width: number, height: number): void {
        this.maxWidth = width;
        this.maxHeight = height;
        logDebug(`DebugImage: Max size set to ${width}x${height}`);
    }

    /**
     * Show the panel with specified size
     */
    display(width: number, height: number, x?: number, y?: number): void {
        this.currentWidth = width;
        this.currentHeight = height;
        this.ensurePanel();
        logDebug(`DebugImage: Display ${width}x${height}${x !== undefined ? ` at (${x},${y})` : ''}`);
    }

    /**
     * Hide the panel
     */
    hide(): void {
        if (this.panel) {
            this.panel.dispose();
            this.panel = undefined;
        }
        logDebug('DebugImage: Hidden');
    }

    /**
     * Update the image with raw BGRA pixel data
     */
    updateImage(width: number, height: number, bgraData: Buffer, resize: boolean, ensureVisible: boolean): void {
        logDebug(`DebugImage: Update ${width}x${height}, resize=${resize}, visible=${ensureVisible}`);

        if (ensureVisible) {
            this.ensurePanel();
        }

        if (!this.panel) {
            return;
        }

        // Apply max size constraints if set
        let displayWidth = width;
        let displayHeight = height;
        if (this.maxWidth > 0 && width > this.maxWidth) {
            const scale = this.maxWidth / width;
            displayWidth = this.maxWidth;
            displayHeight = Math.floor(height * scale);
        }
        if (this.maxHeight > 0 && displayHeight > this.maxHeight) {
            const scale = this.maxHeight / displayHeight;
            displayHeight = this.maxHeight;
            displayWidth = Math.floor(displayWidth * scale);
        }

        // Convert BGRA to RGBA for canvas
        const rgbaData = this.bgraToRgba(bgraData, width, height);

        // Create base64 data URL
        const base64Data = rgbaData.toString('base64');

        // Send to webview
        this.panel.webview.postMessage({
            type: 'updateImage',
            width: width,
            height: height,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            data: base64Data
        });

        if (resize) {
            this.currentWidth = displayWidth;
            this.currentHeight = displayHeight;
        }
    }

    /**
     * Convert BGRA to RGBA (swap B and R channels)
     */
    private bgraToRgba(bgra: Buffer, width: number, height: number): Buffer {
        const rgba = Buffer.alloc(width * height * 4);
        for (let i = 0; i < width * height; i++) {
            const offset = i * 4;
            rgba[offset] = bgra[offset + 2];     // R <- B
            rgba[offset + 1] = bgra[offset + 1]; // G <- G
            rgba[offset + 2] = bgra[offset];     // B <- R
            rgba[offset + 3] = bgra[offset + 3]; // A <- A
        }
        return rgba;
    }

    /**
     * Ensure the WebView panel exists
     */
    private ensurePanel(): void {
        if (this.panel) {
            this.panel.reveal(ViewColumn.Beside, true);
            return;
        }

        this.panel = window.createWebviewPanel(
            'simbaDebugImage',
            'Simba Debug Image',
            { viewColumn: ViewColumn.Beside, preserveFocus: true },
            {
                enableScripts: true,
                retainContextWhenHidden: true
            }
        );

        this.panel.webview.html = this.getWebviewContent();

        this.panel.onDidDispose(() => {
            this.panel = undefined;
        });
    }

    /**
     * Get the HTML content for the WebView
     */
    private getWebviewContent(): string {
        return `<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            margin: 0;
            padding: 10px;
            background-color: var(--vscode-editor-background);
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        #info {
            color: var(--vscode-foreground);
            font-family: var(--vscode-font-family);
            font-size: 12px;
            margin-bottom: 10px;
        }
        #canvas {
            border: 1px solid var(--vscode-panel-border);
            image-rendering: pixelated;
        }
    </style>
</head>
<body>
    <div id="info">Waiting for image...</div>
    <canvas id="canvas"></canvas>
    <script>
        const vscode = acquireVsCodeApi();
        const canvas = document.getElementById('canvas');
        const ctx = canvas.getContext('2d');
        const info = document.getElementById('info');

        window.addEventListener('message', event => {
            const message = event.data;
            if (message.type === 'updateImage') {
                const { width, height, displayWidth, displayHeight, data } = message;

                // Set canvas size
                canvas.width = width;
                canvas.height = height;
                canvas.style.width = displayWidth + 'px';
                canvas.style.height = displayHeight + 'px';

                // Decode base64 RGBA data
                const binaryString = atob(data);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {
                    bytes[i] = binaryString.charCodeAt(i);
                }

                // Create ImageData and draw
                const imageData = new ImageData(new Uint8ClampedArray(bytes.buffer), width, height);
                ctx.putImageData(imageData, 0, 0);

                // Update info
                info.textContent = width + 'x' + height + (displayWidth !== width ? ' (scaled to ' + displayWidth + 'x' + displayHeight + ')' : '');
            }
        });
    </script>
</body>
</html>`;
    }
}

/**
 * Debug Matrix Panel - WebView for displaying Simba debug matrices
 */
class DebugMatrixPanel {
    private static instance: DebugMatrixPanel | undefined;
    private panel: WebviewPanel | undefined;
    private matrixData: Float32Array | undefined;
    private matrixWidth: number = 0;
    private matrixHeight: number = 0;

    private constructor() {}

    static getInstance(): DebugMatrixPanel {
        if (!DebugMatrixPanel.instance) {
            DebugMatrixPanel.instance = new DebugMatrixPanel();
        }
        return DebugMatrixPanel.instance;
    }

    /**
     * Hide the panel
     */
    hide(): void {
        if (this.panel) {
            this.panel.dispose();
            this.panel = undefined;
        }
        logDebug('DebugMatrix: Hidden');
    }

    /**
     * Update the matrix with float data and render as colored image
     * @param width Matrix width
     * @param height Matrix height
     * @param floatData Raw float32 matrix data
     * @param resize Whether to resize the panel
     * @param ensureVisible Whether to show the panel if hidden
     * @param colorMapType The color mapping type (0-4 or custom hue)
     */
    updateMatrix(width: number, height: number, floatData: Buffer, resize: boolean, ensureVisible: boolean, colorMapType: number): void {
        logDebug(`DebugMatrix: Update ${width}x${height}, colorMap=${colorMapType}, resize=${resize}, visible=${ensureVisible}`);

        if (ensureVisible) {
            this.ensurePanel();
        }

        if (!this.panel) {
            return;
        }

        this.matrixWidth = width;
        this.matrixHeight = height;

        // Convert Buffer to Float32Array
        this.matrixData = new Float32Array(floatData.buffer, floatData.byteOffset, width * height);

        // Find min/max for normalization
        let min = Infinity;
        let max = -Infinity;
        for (let i = 0; i < this.matrixData.length; i++) {
            const val = this.matrixData[i];
            if (val < min) min = val;
            if (val > max) max = val;
        }

        // Normalize to 0-1 range
        const range = max - min;
        const normalizedData: number[] = [];
        for (let i = 0; i < this.matrixData.length; i++) {
            normalizedData.push(range > 0 ? (this.matrixData[i] - min) / range : 0);
        }

        // Convert to RGBA using color mapping
        const rgbaData = this.matrixToRgba(normalizedData, width, height, colorMapType);

        // Create base64 data URL
        const base64Data = rgbaData.toString('base64');

        // Send to webview
        this.panel.webview.postMessage({
            type: 'updateMatrix',
            width: width,
            height: height,
            data: base64Data,
            min: min,
            max: max
        });

        logDebug(`DebugMatrix: Sent ${width}x${height} matrix (min=${min.toFixed(4)}, max=${max.toFixed(4)})`);
    }

    /**
     * Convert normalized matrix values to RGBA using color mapping
     */
    private matrixToRgba(normalizedData: number[], width: number, height: number, colorMapType: number): Buffer {
        const rgba = Buffer.alloc(width * height * 4);

        for (let i = 0; i < normalizedData.length; i++) {
            const value = normalizedData[i];
            const [r, g, b] = this.getMatrixColor(value, colorMapType);
            const offset = i * 4;
            rgba[offset] = r;
            rgba[offset + 1] = g;
            rgba[offset + 2] = b;
            rgba[offset + 3] = 255; // Alpha
        }

        return rgba;
    }

    /**
     * Get RGB color for a normalized value (0-1) based on color map type
     * Matches Simba's GetMatrixColor function
     */
    private getMatrixColor(value: number, colorMapType: number): [number, number, number] {
        switch (colorMapType) {
            case 0: // cold blue to red (heatmap)
                return this.hslToRgb((1 - value) * 240, 40 + value * 60, 50);
            case 1: // black -> blue -> red
                return this.hslToRgb((1 - value) * 240, 100, value * 50);
            case 2: // white -> blue -> red
                return this.hslToRgb((1 - value) * 240, 100, 100 - value * 50);
            case 3: // light (to white) - grayscale
                return this.hslToRgb(0, 0, (1 - value) * 100);
            case 4: // light (to black) - grayscale inverted
                return this.hslToRgb(0, 0, value * 100);
            default: // custom: black to hue to white
                return this.hslToRgb(colorMapType, 100, value * 100);
        }
    }

    /**
     * Convert HSL to RGB
     * H: 0-360, S: 0-100, L: 0-100
     * Returns [R, G, B] each 0-255
     */
    private hslToRgb(h: number, s: number, l: number): [number, number, number] {
        // Normalize to 0-1 range
        h = h / 360;
        s = s / 100;
        l = l / 100;

        if (s === 0) {
            // Achromatic (gray)
            const gray = Math.round(l * 255);
            return [gray, gray, gray];
        }

        const hue2rgb = (m1: number, m2: number, hue: number): number => {
            if (hue < 0) hue += 1;
            if (hue > 1) hue -= 1;

            if (6 * hue < 1) {
                return Math.round(255 * (m1 + (m2 - m1) * 6 * hue));
            } else if (2 * hue < 1) {
                return Math.round(255 * m2);
            } else if (3 * hue < 2) {
                return Math.round(255 * (m1 + (m2 - m1) * ((2 / 3) - hue) * 6));
            } else {
                return Math.round(255 * m1);
            }
        };

        const m2 = l < 0.5 ? l * (1 + s) : (l + s) - (s * l);
        const m1 = 2 * l - m2;

        return [
            hue2rgb(m1, m2, h + 1 / 3),
            hue2rgb(m1, m2, h),
            hue2rgb(m1, m2, h - 1 / 3)
        ];
    }

    /**
     * Ensure the WebView panel exists
     */
    private ensurePanel(): void {
        if (this.panel) {
            this.panel.reveal(ViewColumn.Beside, true);
            return;
        }

        this.panel = window.createWebviewPanel(
            'simbaDebugMatrix',
            'Simba Debug Matrix',
            { viewColumn: ViewColumn.Beside, preserveFocus: true },
            {
                enableScripts: true,
                retainContextWhenHidden: true
            }
        );

        this.panel.webview.html = this.getWebviewContent();

        this.panel.onDidDispose(() => {
            this.panel = undefined;
        });
    }

    /**
     * Get the HTML content for the WebView
     */
    private getWebviewContent(): string {
        return `<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            margin: 0;
            padding: 10px;
            background-color: var(--vscode-editor-background);
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        #info {
            color: var(--vscode-foreground);
            font-family: var(--vscode-font-family);
            font-size: 12px;
            margin-bottom: 10px;
        }
        #canvas-container {
            position: relative;
        }
        #canvas {
            border: 1px solid var(--vscode-panel-border);
            image-rendering: pixelated;
        }
        #tooltip {
            position: fixed;
            background: var(--vscode-editorHoverWidget-background);
            border: 1px solid var(--vscode-editorHoverWidget-border);
            color: var(--vscode-foreground);
            font-family: var(--vscode-font-family);
            font-size: 12px;
            padding: 4px 8px;
            pointer-events: none;
            display: none;
            z-index: 1000;
        }
    </style>
</head>
<body>
    <div id="info">Waiting for matrix data...</div>
    <div id="canvas-container">
        <canvas id="canvas"></canvas>
    </div>
    <div id="tooltip"></div>
    <script>
        const vscode = acquireVsCodeApi();
        const canvas = document.getElementById('canvas');
        const ctx = canvas.getContext('2d');
        const info = document.getElementById('info');
        const tooltip = document.getElementById('tooltip');

        let matrixWidth = 0;
        let matrixHeight = 0;
        let minVal = 0;
        let maxVal = 1;

        canvas.addEventListener('mousemove', (e) => {
            const rect = canvas.getBoundingClientRect();
            const scaleX = canvas.width / rect.width;
            const scaleY = canvas.height / rect.height;
            const x = Math.floor((e.clientX - rect.left) * scaleX);
            const y = Math.floor((e.clientY - rect.top) * scaleY);

            if (x >= 0 && x < matrixWidth && y >= 0 && y < matrixHeight) {
                // Get pixel color to estimate value
                const imageData = ctx.getImageData(x, y, 1, 1).data;
                const r = imageData[0], g = imageData[1], b = imageData[2];

                tooltip.style.display = 'block';
                tooltip.style.left = (e.clientX + 10) + 'px';
                tooltip.style.top = (e.clientY + 10) + 'px';
                tooltip.textContent = 'Matrix[' + y + ',' + x + '] RGB(' + r + ',' + g + ',' + b + ')';
            } else {
                tooltip.style.display = 'none';
            }
        });

        canvas.addEventListener('mouseleave', () => {
            tooltip.style.display = 'none';
        });

        canvas.addEventListener('dblclick', (e) => {
            const rect = canvas.getBoundingClientRect();
            const scaleX = canvas.width / rect.width;
            const scaleY = canvas.height / rect.height;
            const x = Math.floor((e.clientX - rect.left) * scaleX);
            const y = Math.floor((e.clientY - rect.top) * scaleY);

            if (x >= 0 && x < matrixWidth && y >= 0 && y < matrixHeight) {
                vscode.postMessage({ type: 'click', x: x, y: y });
            }
        });

        window.addEventListener('message', event => {
            const message = event.data;
            if (message.type === 'updateMatrix') {
                const { width, height, data, min, max } = message;

                matrixWidth = width;
                matrixHeight = height;
                minVal = min;
                maxVal = max;

                // Set canvas size
                canvas.width = width;
                canvas.height = height;

                // Scale display for better visibility
                const maxDisplaySize = 500;
                const scale = Math.min(maxDisplaySize / width, maxDisplaySize / height, 4);
                canvas.style.width = Math.floor(width * scale) + 'px';
                canvas.style.height = Math.floor(height * scale) + 'px';

                // Decode base64 RGBA data
                const binaryString = atob(data);
                const bytes = new Uint8Array(binaryString.length);
                for (let i = 0; i < binaryString.length; i++) {
                    bytes[i] = binaryString.charCodeAt(i);
                }

                // Create ImageData and draw
                const imageData = new ImageData(new Uint8ClampedArray(bytes.buffer), width, height);
                ctx.putImageData(imageData, 0, 0);

                // Update info
                info.textContent = width + 'x' + height + ' | Range: [' + min.toFixed(4) + ', ' + max.toFixed(4) + ']';
            }
        });
    </script>
</body>
</html>`;
    }
}

/**
 * Simba IPC Message IDs (from ESimbaCommunicationMessage enum)
 */
const enum SimbaMessageID {
    SIMBA_TITLE = 0,
    SIMBA_PID = 1,
    SIMBA_TARGET_PID = 2,
    SIMBA_TARGET_WINDOW = 3,
    SCRIPT = 4,
    SCRIPT_ERROR = 5,
    SCRIPT_STATE_CHANGE = 6,
    TRAY_NOTIFICATION = 7,
    DEBUGIMAGE_UPDATE = 8,
    DEBUGIMAGE_MAXSIZE = 9,
    DEBUGIMAGE_HIDE = 10,
    DEBUGIMAGE_DISPLAY = 11,
    DEBUGIMAGE_DISPLAY_XY = 12,
    DEBUGMATRIX_UPDATE = 13
}

/**
 * IPC Server that mimics Simba IDE communication
 * Handles messages from running scripts (like GetSimbaTargetWindow)
 */
class SimbaIPCServer {
    private outputStream: NodeJS.WritableStream | null = null;
    private clientId: string = '';
    private targetWindowHandle: bigint = BigInt(0);
    private targetProcessId: number = 0;
    private buffer: Buffer = Buffer.alloc(0);
    private headerSize = 8; // 4 bytes Size + 4 bytes MessageID

    constructor() {}

    /**
     * Set the target window handle that will be returned to scripts
     */
    setTargetWindow(handle: string, pid?: number): void {
        this.targetWindowHandle = BigInt(handle);
        if (pid !== undefined) {
            this.targetProcessId = pid;
        }
    }

    /**
     * Set the target process ID
     */
    setTargetPID(pid: number): void {
        this.targetProcessId = pid;
    }

    /**
     * Get the client ID to pass to Simba via --simbacommunication
     * On Windows, this is hex-encoded pipe handles
     */
    getClientId(): string {
        return this.clientId;
    }

    /**
     * Create IPC pipes and return handles for Windows
     * Returns the client ID string or empty string if failed
     */
    async createPipes(): Promise<{
        clientId: string;
        scriptStdin: NodeJS.WritableStream;
        scriptStdout: NodeJS.ReadableStream;
    } | null> {
        // On Windows, we need to create pipes with inheritable handles
        // and get their raw handle numbers
        if (os.platform() === 'win32') {
            return this.createWindowsPipes();
        } else {
            // On Unix, we can use file descriptors more easily
            return this.createUnixPipes();
        }
    }

    /**
     * Create pipes on Windows using PowerShell to get handle numbers
     */
    private async createWindowsPipes(): Promise<{
        clientId: string;
        scriptStdin: NodeJS.WritableStream;
        scriptStdout: NodeJS.ReadableStream;
    } | null> {
        // For Windows, we'll use a different approach:
        // Spawn Simba with stdio pipes, and use fd 3 and 4 for IPC
        // Actually, we need to create actual Windows pipes and get their handles

        // This is complex - for now, let's use a workaround:
        // Create the process and handle IPC through additional stdio pipes
        return null; // Will be set up during process spawn
    }

    /**
     * Create pipes on Unix systems
     */
    private async createUnixPipes(): Promise<{
        clientId: string;
        scriptStdin: NodeJS.WritableStream;
        scriptStdout: NodeJS.ReadableStream;
    } | null> {
        return null; // Unix not implemented yet
    }

    /**
     * Set up the output stream for sending IPC responses
     */
    setOutputStream(outputStream: NodeJS.WritableStream): void {
        this.outputStream = outputStream;
        logDebug('IPC handler started');
    }

    /**
     * Feed IPC data from external source (called when we decode IPC data from stderr)
     */
    feedData(data: Buffer): void {
        logDebug(`IPC received ${data.length} bytes`);
        this.handleData(data);
    }

    /**
     * Check if buffer starts with Simba's DebugLn text output format
     * Format: \0\0 + 6 hex chars (flags) + message + newline
     */
    private isSimbaTextOutput(): boolean {
        if (this.buffer.length < 8) return false;
        // Check for \0\0 prefix followed by 6 hex ASCII chars (0-9, A-F)
        if (this.buffer[0] !== 0 || this.buffer[1] !== 0) return false;
        for (let i = 2; i < 8; i++) {
            const c = this.buffer[i];
            const isHex = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
            if (!isHex) return false;
        }
        return true;
    }

    /**
     * Check if buffer looks like plain ASCII text (script WriteLn output)
     * Returns true if the data appears to be printable text
     */
    private isPlainTextOutput(): boolean {
        if (this.buffer.length < 4) return false;

        // Check if first 4 bytes interpreted as size would be unreasonably large
        const wouldBeSize = this.buffer.readInt32LE(0);
        if (wouldBeSize >= 0 && wouldBeSize < 100000) return false; // Could be valid IPC

        // Check if first several bytes are printable ASCII (or common control chars)
        let printableCount = 0;
        const checkLen = Math.min(20, this.buffer.length);
        for (let i = 0; i < checkLen; i++) {
            const c = this.buffer[i];
            // Printable ASCII (32-126) or common control chars (tab, newline, carriage return)
            if ((c >= 32 && c <= 126) || c === 9 || c === 10 || c === 13) {
                printableCount++;
            }
        }

        // If most bytes are printable, it's probably text
        return printableCount > checkLen * 0.7;
    }

    /**
     * Extract and display Simba text output from buffer
     * Returns true if text was extracted
     */
    private extractSimbaTextOutput(): boolean {
        // Find newline to get complete line
        const newlineIdx = this.buffer.indexOf(0x0A); // \n
        if (newlineIdx === -1) {
            // Also check for \r\n
            const crIdx = this.buffer.indexOf(0x0D);
            if (crIdx === -1) return false; // No complete line yet
        }

        // Extract the line (up to and including newline)
        const lineEndIdx = this.buffer.indexOf(0x0A);
        const lineEnd = lineEndIdx !== -1 ? lineEndIdx + 1 : this.buffer.indexOf(0x0D) + 1;

        if (lineEnd <= 0) return false;

        const line = this.buffer.slice(0, lineEnd);
        this.buffer = this.buffer.slice(lineEnd);

        // Parse the line: \0\0 + 6 hex flags + message
        if (line.length >= 8) {
            const flagsHex = line.slice(2, 8).toString('ascii');
            const message = line.slice(8).toString('utf8').trim();

            // Display the message (flags indicate color/importance)
            if (scriptOutputChannel && message.length > 0) {
                scriptOutputChannel.appendLine(message);
            }
        }

        return true;
    }

    /**
     * Extract and display plain text output (without \0\0 prefix)
     * Returns true if text was extracted
     */
    private extractPlainTextOutput(): boolean {
        // Find newline to get complete line
        let lineEnd = this.buffer.indexOf(0x0A); // \n
        if (lineEnd === -1) {
            lineEnd = this.buffer.indexOf(0x0D); // \r
        }
        if (lineEnd === -1) return false; // No complete line yet

        // Include the newline character
        lineEnd++;

        const line = this.buffer.slice(0, lineEnd);
        this.buffer = this.buffer.slice(lineEnd);

        const message = line.toString('utf8').trim();
        if (scriptOutputChannel && message.length > 0) {
            scriptOutputChannel.appendLine(message);
        }

        return true;
    }

    /**
     * Check if buffer looks like a valid IPC message
     * Valid IPC: size 0-1000, messageId 0-20
     */
    private looksLikeValidIPC(): boolean {
        if (this.buffer.length < this.headerSize) return false;

        const size = this.buffer.readInt32LE(0);
        const messageId = this.buffer.readInt32LE(4);

        // Valid IPC messages have small sizes and known message IDs
        // ESimbaCommunicationMessage has ~14 values (0-13)
        return size >= 0 && size <= 10000 && messageId >= 0 && messageId <= 20;
    }

    /**
     * Handle incoming data from the script
     * This handles BOTH Simba's text output (DebugLn) AND binary IPC messages
     */
    private handleData(chunk: Buffer): void {
        // Append to buffer
        this.buffer = Buffer.concat([this.buffer, chunk]);

        const preview = this.buffer.slice(0, Math.min(16, this.buffer.length));
        logDebug(`IPC buffer: ${this.buffer.length} bytes, hex: ${preview.toString('hex')}`);

        // Process all available data
        while (this.buffer.length > 0) {
            // First check if this is Simba text output (\0\0 + hex flags + text)
            if (this.isSimbaTextOutput()) {
                if (!this.extractSimbaTextOutput()) {
                    // Need more data for complete line
                    break;
                }
                continue;
            }

            // Check if this looks like a valid IPC message BEFORE checking plain text
            // This prevents text from being mistaken for IPC when size happens to be small
            if (this.looksLikeValidIPC()) {
                const size = this.buffer.readInt32LE(0);
                const messageId = this.buffer.readInt32LE(4);

                // Special handling for DEBUGIMAGE_UPDATE - size=0 means raw data follows
                if (messageId === SimbaMessageID.DEBUGIMAGE_UPDATE && size === 0) {
                    // Need at least: header(8) + width(4) + height(4) + resize(1) + visible(1) = 18 bytes
                    if (this.buffer.length < 18) {
                        logDebug(`IPC DEBUGIMAGE_UPDATE waiting for header: need 18 bytes, have ${this.buffer.length}`);
                        break;
                    }

                    const width = this.buffer.readInt32LE(8);
                    const height = this.buffer.readInt32LE(12);
                    const resize = this.buffer[16] !== 0;
                    const ensureVisible = this.buffer[17] !== 0;
                    const pixelDataSize = width * height * 4;
                    const totalImageSize = 18 + pixelDataSize;

                    if (this.buffer.length < totalImageSize) {
                        logDebug(`IPC DEBUGIMAGE_UPDATE waiting for pixels: need ${totalImageSize} bytes, have ${this.buffer.length}`);
                        break;
                    }

                    // Extract pixel data
                    const pixelData = this.buffer.slice(18, totalImageSize);

                    logDebug(`IPC DEBUGIMAGE_UPDATE: ${width}x${height}, resize=${resize}, visible=${ensureVisible}, pixels=${pixelData.length}`);

                    // Update the debug image panel
                    const debugPanel = DebugImagePanel.getInstance();
                    debugPanel.updateImage(width, height, pixelData, resize, ensureVisible);

                    // Send empty response
                    this.sendResponse(messageId, Buffer.alloc(0));

                    // Remove processed message from buffer
                    this.buffer = this.buffer.slice(totalImageSize);
                    continue;
                }

                // Special handling for DEBUGMATRIX_UPDATE - size=0 means raw data follows
                if (messageId === SimbaMessageID.DEBUGMATRIX_UPDATE && size === 0) {
                    // Need at least: header(8) + width(4) + height(4) + resize(1) + visible(1) + colorMapType(4) = 22 bytes
                    if (this.buffer.length < 22) {
                        logDebug(`IPC DEBUGMATRIX_UPDATE waiting for header: need 22 bytes, have ${this.buffer.length}`);
                        break;
                    }

                    const width = this.buffer.readInt32LE(8);
                    const height = this.buffer.readInt32LE(12);
                    const resize = this.buffer[16] !== 0;
                    const ensureVisible = this.buffer[17] !== 0;
                    const colorMapType = this.buffer.readInt32LE(18);
                    const floatDataSize = width * height * 4; // Single = 4 bytes
                    const totalMatrixSize = 22 + floatDataSize;

                    if (this.buffer.length < totalMatrixSize) {
                        logDebug(`IPC DEBUGMATRIX_UPDATE waiting for data: need ${totalMatrixSize} bytes, have ${this.buffer.length}`);
                        break;
                    }

                    // Extract float data
                    const floatData = this.buffer.slice(22, totalMatrixSize);

                    logDebug(`IPC DEBUGMATRIX_UPDATE: ${width}x${height}, colorMap=${colorMapType}, resize=${resize}, visible=${ensureVisible}, floats=${floatData.length / 4}`);

                    // Update the debug matrix panel
                    const debugMatrixPanel = DebugMatrixPanel.getInstance();
                    debugMatrixPanel.updateMatrix(width, height, floatData, resize, ensureVisible, colorMapType);

                    // Send empty response
                    this.sendResponse(messageId, Buffer.alloc(0));

                    // Remove processed message from buffer
                    this.buffer = this.buffer.slice(totalMatrixSize);
                    continue;
                }

                const totalSize = this.headerSize + size;

                if (this.buffer.length < totalSize) {
                    // Wait for more data for complete IPC message
                    logDebug(`IPC waiting: need ${totalSize} bytes, have ${this.buffer.length}`);
                    break;
                }

                // Extract params
                const params = this.buffer.slice(this.headerSize, totalSize);

                logDebug(`IPC processing message ${messageId} with ${params.length} bytes`);

                // Process message
                const result = this.processMessage(messageId, params);

                // Send response
                this.sendResponse(messageId, result);

                // Remove processed message from buffer
                this.buffer = this.buffer.slice(totalSize);

                logDebug(`IPC response sent, ${this.buffer.length} bytes remaining`);
                continue;
            }

            // Check if this looks like plain ASCII text (script WriteLn output)
            if (this.isPlainTextOutput()) {
                if (!this.extractPlainTextOutput()) {
                    // Need more data for complete line
                    break;
                }
                continue;
            }

            // Fallback: try to extract any printable text up to newline
            const newlineIdx = this.buffer.indexOf(0x0A);
            if (newlineIdx !== -1) {
                const line = this.buffer.slice(0, newlineIdx + 1).toString('utf8').trim();
                this.buffer = this.buffer.slice(newlineIdx + 1);
                if (scriptOutputChannel && line.length > 0) {
                    scriptOutputChannel.appendLine(line);
                }
                continue;
            }

            // No newline found, check if we have incomplete data
            if (this.buffer.length < 100) {
                // Small buffer without newline - wait for more data
                logDebug(`IPC waiting for more data (${this.buffer.length} bytes, no newline)`);
                break;
            }

            // Large buffer without pattern match - skip first byte
            logDebug(`IPC skipping unrecognized byte: 0x${this.buffer[0].toString(16)}`);
            this.buffer = this.buffer.slice(1);
        }
    }

    // Script info for SCRIPT message
    private scriptName: string = '';
    private scriptContent: string = '';

    setScriptInfo(name: string, content: string): void {
        this.scriptName = name;
        this.scriptContent = content;
    }

    /**
     * Write a Pascal AnsiString to a buffer
     * Format: 4-byte length + string bytes (no null terminator)
     */
    private writeAnsiString(str: string): Buffer {
        const strBytes = Buffer.from(str, 'utf8');
        const result = Buffer.alloc(4 + strBytes.length);
        result.writeInt32LE(strBytes.length, 0);
        strBytes.copy(result, 4);
        return result;
    }

    /**
     * Process an IPC message and return the result
     */
    private processMessage(messageId: number, params: Buffer): Buffer {
        switch (messageId) {
            case SimbaMessageID.SCRIPT:
                // Return script name and content as AnsiStrings
                logDebug(`IPC GetScript -> name="${this.scriptName}", contentLen=${this.scriptContent.length}`);
                const nameBuffer = this.writeAnsiString(this.scriptName);
                const contentBuffer = this.writeAnsiString(this.scriptContent);
                return Buffer.concat([nameBuffer, contentBuffer]);

            case SimbaMessageID.SIMBA_TARGET_WINDOW:
                // Return the target window handle as UInt64 (8 bytes)
                const result = Buffer.alloc(8);
                result.writeBigUInt64LE(this.targetWindowHandle);
                logDebug(`IPC GetSimbaTargetWindow -> ${this.targetWindowHandle}`);
                return result;

            case SimbaMessageID.SIMBA_PID:
                // Return VSCode's PID
                const pidResult = Buffer.alloc(4);
                pidResult.writeUInt32LE(process.pid);
                logDebug(`IPC GetSimbaPID -> ${process.pid}`);
                return pidResult;

            case SimbaMessageID.SIMBA_TARGET_PID:
                // Return the target window's process ID
                const targetPidResult = Buffer.alloc(4);
                targetPidResult.writeUInt32LE(this.targetProcessId);
                logDebug(`IPC GetSimbaTargetPID -> ${this.targetProcessId}`);
                return targetPidResult;

            case SimbaMessageID.SCRIPT_STATE_CHANGE:
                // Script state changed (running, paused, stopped)
                // ESimbaScriptState: STATE_PAUSED=0, STATE_STOP=1, STATE_RUNNING=2, STATE_NONE=3
                if (params.length >= 4) {
                    const state = params.readInt32LE(0);
                    const stateNames = ['PAUSED', 'STOP', 'RUNNING', 'NONE'];
                    const stateName = stateNames[state] || `UNKNOWN(${state})`;
                    logDebug(`IPC ScriptStateChanged -> ${stateName}`);
                }
                return Buffer.alloc(0);

            case SimbaMessageID.SCRIPT_ERROR:
                // Script error - log it
                logDebug('IPC ScriptError received');
                return Buffer.alloc(0);

            case SimbaMessageID.DEBUGIMAGE_MAXSIZE: {
                // Set max size for debug image
                if (params.length >= 8) {
                    const width = params.readInt32LE(0);
                    const height = params.readInt32LE(4);
                    const debugPanel = DebugImagePanel.getInstance();
                    debugPanel.setMaxSize(width, height);
                }
                return Buffer.alloc(0);
            }

            case SimbaMessageID.DEBUGIMAGE_HIDE: {
                // Hide debug image panel
                const debugPanel = DebugImagePanel.getInstance();
                debugPanel.hide();
                return Buffer.alloc(0);
            }

            case SimbaMessageID.DEBUGIMAGE_DISPLAY: {
                // Display debug image with size
                if (params.length >= 8) {
                    const width = params.readInt32LE(0);
                    const height = params.readInt32LE(4);
                    const debugPanel = DebugImagePanel.getInstance();
                    debugPanel.display(width, height);
                }
                return Buffer.alloc(0);
            }

            case SimbaMessageID.DEBUGIMAGE_DISPLAY_XY: {
                // Display debug image at position with size
                if (params.length >= 16) {
                    const x = params.readInt32LE(0);
                    const y = params.readInt32LE(4);
                    const width = params.readInt32LE(8);
                    const height = params.readInt32LE(12);
                    const debugPanel = DebugImagePanel.getInstance();
                    debugPanel.display(width, height, x, y);
                }
                return Buffer.alloc(0);
            }

            default:
                // Unknown message, return empty
                logDebug(`IPC Unknown message ID: ${messageId}`);
                return Buffer.alloc(0);
        }
    }

    /**
     * Send a response back to the script
     */
    private sendResponse(messageId: number, data: Buffer): void {
        if (!this.outputStream) return;

        // Combine header and data into single buffer to ensure atomic write
        const response = Buffer.alloc(this.headerSize + data.length);
        response.writeInt32LE(data.length, 0);  // Size
        response.writeInt32LE(messageId, 4);    // MessageID
        if (data.length > 0) {
            data.copy(response, this.headerSize);
        }

        logDebug(`IPC sending response: ${response.length} bytes (size=${data.length}, msgId=${messageId})`);

        // Write as single buffer and handle backpressure
        const flushed = this.outputStream.write(response);
        if (!flushed) {
            logDebug('IPC WARNING: Write buffer full, waiting for drain');
        }

        // Force flush by corking/uncorking if available
        const stream = this.outputStream as any;
        if (typeof stream.cork === 'function') {
            stream.cork();
            stream.uncork();
        }
    }

    /**
     * Stop the IPC server
     */
    stop(): void {
        this.outputStream = null;
        this.buffer = Buffer.alloc(0);
    }
}

// Global IPC server instance
let ipcServer: SimbaIPCServer | undefined;

/**
 * Generate the PowerShell script that creates pipes, spawns Simba,
 * and bridges IPC to stdin/stdout
 */
function getIPCBridgeScript(simbaPath: string, scriptPath: string, targetHandle: string): string {
    // This PowerShell script:
    // 1. Creates two anonymous pipes with inheritable handles
    // 2. Spawns Simba with --simbacommunication pointing to those handles
    // 3. Bridges the pipes to PowerShell's stdin/stdout so Node.js can communicate
    // 4. Also captures Simba's stdout/stderr and forwards them
    return `
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Text;
using Microsoft.Win32.SafeHandles;

public class SimbaIPCBridge {
    // Pipe creation
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, ref SECURITY_ATTRIBUTES lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    // CreateProcess with STARTUPINFOEX for explicit handle inheritance
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList,
        uint dwFlags,
        IntPtr Attribute,
        IntPtr lpValue,
        IntPtr cbSize,
        IntPtr lpPreviousValue,
        IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    const uint HANDLE_FLAG_INHERIT = 1;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const int STARTF_USESTDHANDLES = 0x00000100;
    const uint INFINITE = 0xFFFFFFFF;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = (IntPtr)0x00020002;

    // IPC pipe handles
    public IntPtr ScriptWriteHandle;  // Script writes to this (we read)
    public IntPtr ScriptReadHandle;   // Script reads from this (we write)
    public IntPtr OurReadHandle;      // We read from this
    public IntPtr OurWriteHandle;     // We write to this

    // Stdout/stderr pipe handles
    public IntPtr StdoutReadHandle;   // We read stdout from this
    public IntPtr StdoutWriteHandle;  // Child writes stdout here
    public IntPtr StderrReadHandle;   // We read stderr from this
    public IntPtr StderrWriteHandle;  // Child writes stderr here

    private FileStream ipcReadStream;
    private FileStream ipcWriteStream;
    private FileStream stdoutReadStream;
    private FileStream stderrReadStream;
    private Thread stdinThread;
    private Thread ipcThread;
    private Thread stdoutThread;
    private Thread stderrThread;
    private volatile bool running = true;
    private IntPtr processHandle = IntPtr.Zero;

    public bool CreateAllPipes() {
        SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(sa);
        sa.bInheritHandle = true;
        sa.lpSecurityDescriptor = IntPtr.Zero;

        // IPC Pipe 1: Script writes, we read
        IntPtr ipcRead1, ipcWrite1;
        if (!CreatePipe(out ipcRead1, out ipcWrite1, ref sa, 4096)) {
            Console.Error.WriteLine("DEBUG: Failed to create IPC pipe 1");
            return false;
        }

        // IPC Pipe 2: We write, script reads
        IntPtr ipcRead2, ipcWrite2;
        if (!CreatePipe(out ipcRead2, out ipcWrite2, ref sa, 4096)) {
            Console.Error.WriteLine("DEBUG: Failed to create IPC pipe 2");
            CloseHandle(ipcRead1);
            CloseHandle(ipcWrite1);
            return false;
        }

        // Stdout pipe: Child writes, we read
        IntPtr stdoutRead, stdoutWrite;
        if (!CreatePipe(out stdoutRead, out stdoutWrite, ref sa, 4096)) {
            Console.Error.WriteLine("DEBUG: Failed to create stdout pipe");
            CloseHandle(ipcRead1); CloseHandle(ipcWrite1);
            CloseHandle(ipcRead2); CloseHandle(ipcWrite2);
            return false;
        }

        // Stderr pipe: Child writes, we read
        IntPtr stderrRead, stderrWrite;
        if (!CreatePipe(out stderrRead, out stderrWrite, ref sa, 4096)) {
            Console.Error.WriteLine("DEBUG: Failed to create stderr pipe");
            CloseHandle(ipcRead1); CloseHandle(ipcWrite1);
            CloseHandle(ipcRead2); CloseHandle(ipcWrite2);
            CloseHandle(stdoutRead); CloseHandle(stdoutWrite);
            return false;
        }

        // Make our read ends non-inheritable (child doesn't need them)
        SetHandleInformation(ipcRead1, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(ipcWrite2, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0);

        ScriptWriteHandle = ipcWrite1;
        ScriptReadHandle = ipcRead2;
        OurReadHandle = ipcRead1;
        OurWriteHandle = ipcWrite2;
        StdoutReadHandle = stdoutRead;
        StdoutWriteHandle = stdoutWrite;
        StderrReadHandle = stderrRead;
        StderrWriteHandle = stderrWrite;

        Console.Error.WriteLine("DEBUG: All pipes created - IPC: Write=" + ScriptWriteHandle.ToInt64().ToString("X") +
                               ", Read=" + ScriptReadHandle.ToInt64().ToString("X") +
                               " | Stdout=" + StdoutWriteHandle.ToInt64().ToString("X") +
                               ", Stderr=" + StderrWriteHandle.ToInt64().ToString("X"));

        return true;
    }

    public string GetClientId() {
        return ScriptWriteHandle.ToInt64().ToString("X16") + ScriptReadHandle.ToInt64().ToString("X16");
    }

    public int StartProcess(string exePath, string arguments, string workingDir) {
        // Build command line
        StringBuilder cmdLine = new StringBuilder();
        cmdLine.Append("\\"" + exePath + "\\" " + arguments);

        // Handles that the child process needs to inherit
        IntPtr[] inheritHandles = new IntPtr[] {
            ScriptWriteHandle,   // IPC write
            ScriptReadHandle,    // IPC read
            StdoutWriteHandle,   // stdout
            StderrWriteHandle    // stderr
        };

        // Allocate attribute list
        IntPtr lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        IntPtr lpAttributeList = Marshal.AllocHGlobal(lpSize);

        try {
            if (!InitializeProcThreadAttributeList(lpAttributeList, 1, 0, ref lpSize)) {
                Console.Error.WriteLine("DEBUG: InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
                return -1;
            }

            // Pin the handle array and set the attribute
            GCHandle handleArrayHandle = GCHandle.Alloc(inheritHandles, GCHandleType.Pinned);
            try {
                if (!UpdateProcThreadAttribute(
                    lpAttributeList,
                    0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                    handleArrayHandle.AddrOfPinnedObject(),
                    (IntPtr)(inheritHandles.Length * IntPtr.Size),
                    IntPtr.Zero,
                    IntPtr.Zero)) {
                    Console.Error.WriteLine("DEBUG: UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
                    return -1;
                }

                // Setup STARTUPINFOEX
                STARTUPINFOEX si = new STARTUPINFOEX();
                si.StartupInfo.cb = Marshal.SizeOf(si);
                si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                si.StartupInfo.hStdInput = IntPtr.Zero;
                si.StartupInfo.hStdOutput = StdoutWriteHandle;
                si.StartupInfo.hStdError = StderrWriteHandle;
                si.lpAttributeList = lpAttributeList;

                PROCESS_INFORMATION pi;

                Console.Error.WriteLine("DEBUG: Creating process with explicit handle inheritance...");

                if (!CreateProcessW(
                    null,
                    cmdLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,  // Inherit handles
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
                    IntPtr.Zero,
                    workingDir,
                    ref si,
                    out pi)) {
                    Console.Error.WriteLine("DEBUG: CreateProcess failed: " + Marshal.GetLastWin32Error());
                    return -1;
                }

                processHandle = pi.hProcess;
                CloseHandle(pi.hThread);

                // Close child's ends of pipes (we don't need them)
                CloseHandle(StdoutWriteHandle);
                CloseHandle(StderrWriteHandle);
                StdoutWriteHandle = IntPtr.Zero;
                StderrWriteHandle = IntPtr.Zero;

                Console.Error.WriteLine("DEBUG: Process created, PID=" + pi.dwProcessId);
                return pi.dwProcessId;

            } finally {
                handleArrayHandle.Free();
            }
        } finally {
            DeleteProcThreadAttributeList(lpAttributeList);
            Marshal.FreeHGlobal(lpAttributeList);
        }
    }

    public void StartBridging() {
        // IPC read stream
        var safeIpcRead = new SafeFileHandle(OurReadHandle, false);
        var safeIpcWrite = new SafeFileHandle(OurWriteHandle, false);
        ipcReadStream = new FileStream(safeIpcRead, FileAccess.Read, 4096);
        ipcWriteStream = new FileStream(safeIpcWrite, FileAccess.Write, 4096);

        // Stdout/stderr read streams
        var safeStdoutRead = new SafeFileHandle(StdoutReadHandle, false);
        var safeStderrRead = new SafeFileHandle(StderrReadHandle, false);
        stdoutReadStream = new FileStream(safeStdoutRead, FileAccess.Read, 4096);
        stderrReadStream = new FileStream(safeStderrRead, FileAccess.Read, 4096);

        Console.Error.WriteLine("DEBUG: Bridge streams created");

        // Thread to forward Node.js stdin to IPC write pipe
        stdinThread = new Thread(() => {
            Console.Error.WriteLine("DEBUG: stdinThread started");
            var stdin = Console.OpenStandardInput();
            byte[] buffer = new byte[4096];
            try {
                while (running) {
                    int read = stdin.Read(buffer, 0, buffer.Length);
                    if (read == 0) break;
                    Console.Error.WriteLine("DEBUG: stdinThread got " + read + " bytes from Node.js");
                    ipcWriteStream.Write(buffer, 0, read);
                    ipcWriteStream.Flush();
                }
            } catch (Exception ex) {
                Console.Error.WriteLine("DEBUG: stdinThread exception: " + ex.Message);
            }
        });
        stdinThread.IsBackground = true;
        stdinThread.Start();

        // Thread to forward IPC data to Node.js stderr (as base64)
        ipcThread = new Thread(() => {
            Console.Error.WriteLine("DEBUG: ipcThread started");
            byte[] buffer = new byte[4096];
            try {
                while (running) {
                    int read = ipcReadStream.Read(buffer, 0, buffer.Length);
                    if (read == 0) break;
                    Console.Error.WriteLine("DEBUG: ipcThread got " + read + " bytes");
                    string base64Data = Convert.ToBase64String(buffer, 0, read);
                    Console.Error.WriteLine("IPC:" + base64Data);
                }
            } catch (Exception ex) {
                if (running) Console.Error.WriteLine("DEBUG: ipcThread exception: " + ex.Message);
            }
        });
        ipcThread.IsBackground = true;
        ipcThread.Start();

        // Thread to forward stdout to Node.js stderr (as SIMBA: lines)
        stdoutThread = new Thread(() => {
            Console.Error.WriteLine("DEBUG: stdoutThread started");
            try {
                using (var reader = new StreamReader(stdoutReadStream, Encoding.UTF8)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        Console.Error.WriteLine("SIMBA:" + line);
                    }
                }
            } catch (Exception ex) {
                if (running) Console.Error.WriteLine("DEBUG: stdoutThread exception: " + ex.Message);
            }
        });
        stdoutThread.IsBackground = true;
        stdoutThread.Start();

        // Thread to forward stderr to Node.js stderr (as SIMBA: lines)
        stderrThread = new Thread(() => {
            Console.Error.WriteLine("DEBUG: stderrThread started");
            try {
                using (var reader = new StreamReader(stderrReadStream, Encoding.UTF8)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        Console.Error.WriteLine("SIMBA:" + line);
                    }
                }
            } catch (Exception ex) {
                if (running) Console.Error.WriteLine("DEBUG: stderrThread exception: " + ex.Message);
            }
        });
        stderrThread.IsBackground = true;
        stderrThread.Start();

        Console.Error.WriteLine("DEBUG: All bridge threads started");
    }

    public int WaitForExit() {
        if (processHandle == IntPtr.Zero) return -1;
        WaitForSingleObject(processHandle, INFINITE);
        uint exitCode;
        GetExitCodeProcess(processHandle, out exitCode);
        return (int)exitCode;
    }

    public void Cleanup() {
        running = false;
        if (ipcReadStream != null) try { ipcReadStream.Dispose(); } catch {}
        if (ipcWriteStream != null) try { ipcWriteStream.Dispose(); } catch {}
        if (stdoutReadStream != null) try { stdoutReadStream.Dispose(); } catch {}
        if (stderrReadStream != null) try { stderrReadStream.Dispose(); } catch {}
        if (processHandle != IntPtr.Zero) CloseHandle(processHandle);
    }
}
"@

$bridge = New-Object SimbaIPCBridge

[Console]::Error.WriteLine("DEBUG: Creating all pipes...")
if (-not $bridge.CreateAllPipes()) {
    [Console]::Error.WriteLine("ERROR: Failed to create pipes")
    exit 1
}
[Console]::Error.WriteLine("DEBUG: All pipes created successfully")

$clientId = $bridge.GetClientId()
$targetHandle = "${targetHandle}"
[Console]::Error.WriteLine("DEBUG: ClientId=$clientId, Target=$targetHandle")

# Start IPC and output bridging
[Console]::Error.WriteLine("DEBUG: Starting bridge threads...")
$bridge.StartBridging()
[Console]::Error.WriteLine("DEBUG: Bridge threads started")

# Build command line arguments
$simbaArgs = "--run --simbacommunication=$clientId --target=$targetHandle " + '"${scriptPath}"'
[Console]::Error.WriteLine("DEBUG: Starting Simba with args: $simbaArgs")

# Start process with explicit handle inheritance
$simbaPid = $bridge.StartProcess("${simbaPath}", $simbaArgs, "${path.dirname(scriptPath)}")
if ($simbaPid -lt 0) {
    [Console]::Error.WriteLine("ERROR: Failed to start Simba process")
    $bridge.Cleanup()
    exit 1
}
[Console]::Error.WriteLine("DEBUG: Simba started with PID=$simbaPid")

# Wait for process to exit
[Console]::Error.WriteLine("DEBUG: Waiting for Simba to exit...")
$exitCode = $bridge.WaitForExit()
[Console]::Error.WriteLine("DEBUG: Simba exited with code $exitCode")

# Give threads a moment to flush output
Start-Sleep -Milliseconds 500

# Cleanup
$bridge.Cleanup()

exit $exitCode
`;
}

/**
 * Get list of open windows (platform-specific)
 */
async function getOpenWindows(): Promise<WindowInfo[]> {
    const platform = os.platform();
    const windows: WindowInfo[] = [];

    return new Promise((resolve) => {
        if (platform === 'win32') {
            // Windows: Use PowerShell to enumerate windows
            const ps = spawn('powershell.exe', ['-NoProfile', '-Command', `
                Add-Type @"
                    using System;
                    using System.Runtime.InteropServices;
                    using System.Text;
                    using System.Collections.Generic;
                    using System.Diagnostics;
                    public class WindowEnumerator {
                        [DllImport("user32.dll")]
                        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
                        [DllImport("user32.dll")]
                        private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
                        [DllImport("user32.dll")]
                        private static extern bool IsWindowVisible(IntPtr hWnd);
                        [DllImport("user32.dll")]
                        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
                        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
                        public static List<string> GetWindows() {
                            var result = new List<string>();
                            EnumWindows((hWnd, lParam) => {
                                if (IsWindowVisible(hWnd)) {
                                    StringBuilder title = new StringBuilder(256);
                                    GetWindowText(hWnd, title, 256);
                                    if (title.Length > 0) {
                                        uint pid;
                                        GetWindowThreadProcessId(hWnd, out pid);
                                        string procName = "";
                                        try { procName = Process.GetProcessById((int)pid).ProcessName; } catch {}
                                        result.Add(hWnd.ToInt64() + "|" + title + "|" + procName + "|" + pid);
                                    }
                                }
                                return true;
                            }, IntPtr.Zero);
                            return result;
                        }
                    }
"@
                [WindowEnumerator]::GetWindows() | ForEach-Object { Write-Output $_ }
            `]);

            let output = '';
            ps.stdout?.on('data', (data: Buffer) => {
                output += data.toString();
            });

            ps.on('close', () => {
                const lines = output.trim().split('\n').filter(l => l.trim());
                for (const line of lines) {
                    const parts = line.trim().split('|');
                    if (parts.length >= 4) {
                        windows.push({
                            handle: parts[0],
                            title: parts[1],
                            processName: parts[2],
                            pid: parseInt(parts[3], 10) || 0
                        });
                    } else if (parts.length >= 3) {
                        // Fallback for older format without PID
                        windows.push({
                            handle: parts[0],
                            title: parts[1],
                            processName: parts[2],
                            pid: 0
                        });
                    }
                }
                resolve(windows);
            });

            ps.on('error', () => resolve(windows));
        } else if (platform === 'darwin') {
            // macOS: Use AppleScript to enumerate windows
            const script = `
                tell application "System Events"
                    set windowList to {}
                    repeat with proc in (every process whose background only is false)
                        try
                            repeat with win in (every window of proc)
                                set winName to name of win
                                set procName to name of proc
                                set end of windowList to ("0|" & winName & "|" & procName)
                            end repeat
                        end try
                    end repeat
                    return windowList
                end tell
            `;
            const osascript = spawn('osascript', ['-e', script]);

            let output = '';
            osascript.stdout?.on('data', (data: Buffer) => {
                output += data.toString();
            });

            osascript.on('close', () => {
                // Parse AppleScript list output
                const matches = output.match(/0\|[^,}]+\|[^,}]+/g) || [];
                for (const match of matches) {
                    const parts = match.split('|');
                    if (parts.length >= 3) {
                        windows.push({
                            handle: parts[0],
                            title: parts[1].trim(),
                            processName: parts[2].trim(),
                            pid: 0
                        });
                    }
                }
                resolve(windows);
            });

            osascript.on('error', () => resolve(windows));
        } else {
            // Linux: Use wmctrl or xdotool
            const wmctrl = spawn('wmctrl', ['-l', '-p']);

            let output = '';
            wmctrl.stdout?.on('data', (data: Buffer) => {
                output += data.toString();
            });

            wmctrl.on('close', () => {
                const lines = output.trim().split('\n').filter(l => l.trim());
                for (const line of lines) {
                    const parts = line.split(/\s+/);
                    if (parts.length >= 5) {
                        windows.push({
                            handle: parts[0],
                            title: parts.slice(4).join(' '),
                            processName: '',
                            pid: parseInt(parts[2], 10) || 0  // wmctrl -p includes PID as 3rd column
                        });
                    }
                }
                resolve(windows);
            });

            wmctrl.on('error', () => resolve(windows));
        }
    });
}

/**
 * Result of finding LSP server
 */
interface LspServerInfo {
    path: string;
    isStandalone: boolean;  // true if SimbaLSP standalone, false if Simba --lsp
    simbaPath: string;      // Directory containing Simba/SimbaLSP
}

/**
 * Log message only when trace is set to verbose
 */
function logVerbose(message: string): void {
    const traceLevel = workspace.getConfiguration('simba').get<string>('lsp.trace.server', 'off');
    if (traceLevel === 'verbose' && outputChannel) {
        outputChannel.appendLine(message);
    }
}

/**
 * Get include paths from configuration and detect defaults
 */
function getIncludePaths(simbaPath: string): string[] {
    const paths: string[] = [];

    // Get paths from configuration
    const configPaths = workspace.getConfiguration('simba').get<string[]>('includePaths', []);
    logVerbose(`Configured include paths: ${JSON.stringify(configPaths)}`);
    for (const p of configPaths) {
        if (fs.existsSync(p)) {
            paths.push(p);
            logVerbose(`  Added include path: ${p}`);
        } else {
            logVerbose(`  Include path not found (skipped): ${p}`);
        }
    }

    // Add default Simba includes path if it exists
    const defaultIncludesPath = path.join(simbaPath, 'Includes');
    if (fs.existsSync(defaultIncludesPath) && !paths.includes(defaultIncludesPath)) {
        paths.push(defaultIncludesPath);
        logVerbose(`  Added default Simba includes: ${defaultIncludesPath}`);
    }

    // Add workspace folders as potential include paths
    if (workspace.workspaceFolders) {
        for (const folder of workspace.workspaceFolders) {
            const folderPath = folder.uri.fsPath;
            if (!paths.includes(folderPath)) {
                paths.push(folderPath);
                logVerbose(`  Added workspace folder: ${folderPath}`);
            }
        }
    }

    return paths;
}

/**
 * Get the Wasp Launcher Simba directory path (cross-platform)
 * Returns: %LOCALAPPDATA%/com.wasp-launcher.app/Simba on Windows
 */
function getWaspLauncherDir(): string | undefined {
    if (os.platform() !== 'win32') { return undefined; }
    const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    const dir = path.join(localAppData, 'com.wasp-launcher.app', 'Simba');
    return fs.existsSync(dir) ? dir : undefined;
}

/**
 * Find the newest file matching a prefix in a directory (e.g. "Simba-" → "Simba-a7c9ac62d6.exe")
 * The Wasp Launcher uses hashed filenames that change on updates.
 */
function findNewestBinary(dir: string, prefix: string, ext: string): string | undefined {
    try {
        const entries = fs.readdirSync(dir);
        let best: { name: string; mtime: number } | undefined;
        for (const entry of entries) {
            if (entry.startsWith(prefix) && entry.endsWith(ext)) {
                const fullPath = path.join(dir, entry);
                const stat = fs.statSync(fullPath);
                if (!best || stat.mtimeMs > best.mtime) {
                    best = { name: fullPath, mtime: stat.mtimeMs };
                }
            }
        }
        return best?.name;
    } catch {
        return undefined;
    }
}

/**
 * Find the LSP server executable path
 * Priority: 1. Configured SimbaLSP, 2. Auto-detect SimbaLSP, 3. Auto-detect Simba
 */
function findLspServer(): LspServerInfo | undefined {
    const config = workspace.getConfiguration('simba');

    // 1. Check for configured SimbaLSP path
    const simbaLspPath = config.get<string>('lsp.simbaLspPath', '');
    logVerbose(`Checking simbaLspPath: "${simbaLspPath}"`);
    if (simbaLspPath && simbaLspPath.length > 0) {
        if (fs.existsSync(simbaLspPath)) {
            logVerbose(`Using configured SimbaLSP: ${simbaLspPath}`);
            return { path: simbaLspPath, isStandalone: true, simbaPath: path.dirname(simbaLspPath) };
        } else {
            logVerbose(`Configured SimbaLSP not found at: ${simbaLspPath}`);
        }
    }

    // 2. Auto-detect from Wasp Launcher directory (hashed binary names)
    const waspDir = getWaspLauncherDir();
    if (waspDir) {
        const lsp = findNewestBinary(waspDir, 'SimbaLSP', '.exe');
        if (lsp) {
            logVerbose(`Found Wasp Launcher SimbaLSP: ${lsp}`);
            return { path: lsp, isStandalone: true, simbaPath: waspDir };
        }
        const simba = findNewestBinary(waspDir, 'Simba-', '.exe');
        if (simba) {
            logVerbose(`Found Wasp Launcher Simba: ${simba}`);
            return { path: simba, isStandalone: false, simbaPath: waspDir };
        }
    }

    return undefined;
}

/**
 * Start the language server
 */
async function startLanguageServer(context: ExtensionContext): Promise<void> {
    const serverInfo = findLspServer();

    if (!serverInfo) {
        const message = 'Simba LSP server not found. Configure simba.lsp.simbaLspPath in settings, or install SimbaLSP to ~/Simba/';
        outputChannel.appendLine(message);
        window.showWarningMessage(message);
        updateLspStatus('error');
        return;
    }

    // Determine if the path was manually configured or auto-detected
    const configuredLspPath = workspace.getConfiguration('simba').get<string>('lsp.simbaLspPath', '');
    const lspAutoDetected = !(configuredLspPath && configuredLspPath.length > 0 && fs.existsSync(configuredLspPath));
    const lspPathInfo = { path: serverInfo.path, autoDetected: lspAutoDetected };

    if (serverInfo.isStandalone) {
        outputChannel.appendLine(`Found standalone SimbaLSP at: ${serverInfo.path} (${lspAutoDetected ? 'auto-detected' : 'configured'})`);
    } else {
        outputChannel.appendLine(`Found Simba at: ${serverInfo.path} (using --lsp mode, ${lspAutoDetected ? 'auto-detected' : 'configured'})`);
    }

    // Get include paths
    const includePaths = getIncludePaths(serverInfo.simbaPath);
    outputChannel.appendLine(`Simba path: ${serverInfo.simbaPath}`);
    outputChannel.appendLine(`Include paths: ${includePaths.join('; ')}`);

    // Define the server executable
    // Standalone SimbaLSP doesn't need --lsp flag, full Simba does
    // Pass include paths via environment variables
    const serverExecutable: Executable = {
        command: serverInfo.path,
        args: serverInfo.isStandalone ? [] : ['--lsp'],
        options: {
            env: {
                ...process.env,
                SIMBA_PATH: serverInfo.simbaPath,
                SIMBA_INCLUDE_PATHS: includePaths.join(';')
            }
        }
    };

    const serverOptions: ServerOptions = {
        run: serverExecutable,
        debug: serverExecutable
    };

    // Options to control the language client
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'simba' }],
        synchronize: {
            fileEvents: workspace.createFileSystemWatcher('**/*.simba')
        },
        outputChannel: outputChannel,
        traceOutputChannel: outputChannel
    };

    // Create the language client and start the client
    client = new LanguageClient(
        'simbaLanguageServer',
        'Simba Language Server',
        serverOptions,
        clientOptions
    );

    // Track LSP state changes in status bar
    client.onDidChangeState((e) => {
        switch (e.newState) {
            case State.Starting:
                updateLspStatus('starting', lspPathInfo);
                break;
            case State.Running:
                updateLspStatus('running', lspPathInfo);
                break;
            case State.Stopped:
                updateLspStatus('stopped', lspPathInfo);
                break;
        }
    });

    updateLspStatus('starting', lspPathInfo);
    try {
        await client.start();
        outputChannel.appendLine('Simba Language Server started successfully');
    } catch (error) {
        updateLspStatus('error', lspPathInfo);
        outputChannel.appendLine(`Failed to start Simba Language Server: ${error}`);
        window.showErrorMessage(`Failed to start Simba Language Server: ${error}`);
    }
}

/**
 * Stop the language server
 */
async function stopLanguageServer(): Promise<void> {
    if (client) {
        await client.stop();
        client = undefined;
    }
    updateLspStatus('stopped');
}

/**
 * Restart the language server
 */
async function restartLanguageServer(context: ExtensionContext): Promise<void> {
    outputChannel.appendLine('Restarting Simba Language Server...');
    await stopLanguageServer();
    await startLanguageServer(context);
}

/**
 * Find Simba binary for running scripts
 * Priority: 1. Configured runPath, 2. Auto-detect
 */
function findSimbaForRun(): string | undefined {
    const config = workspace.getConfiguration('simba');

    // 1. Check for configured run path
    const runPath = config.get<string>('runPath', '');
    if (runPath && runPath.length > 0 && fs.existsSync(runPath)) {
        return runPath;
    }

    // 2. Auto-detect from Wasp Launcher directory (hashed binary names)
    const waspDir = getWaspLauncherDir();
    if (waspDir) {
        const simba = findNewestBinary(waspDir, 'Simba-', '.exe');
        if (simba) { return simba; }
    }

    return undefined;
}

/**
 * Create status bar items for LSP, script, and target window
 */
function createStatusBarItems(context: ExtensionContext): void {
    // LSP Status (highest priority = leftmost)
    lspStatusBar = window.createStatusBarItem(StatusBarAlignment.Left, 100);
    lspStatusBar.command = 'simba.restartServer';
    lspStatusBar.tooltip = 'Simba Language Server - Click to restart';
    updateLspStatus('stopped');
    lspStatusBar.show();
    context.subscriptions.push(lspStatusBar);

    // Script Status (hidden by default)
    scriptStatusBar = window.createStatusBarItem(StatusBarAlignment.Left, 99);
    scriptStatusBar.command = 'simba.stopScript';
    scriptStatusBar.tooltip = 'Running script - Click to stop';
    scriptStatusBar.hide();
    context.subscriptions.push(scriptStatusBar);

    // Target Window
    targetStatusBar = window.createStatusBarItem(StatusBarAlignment.Left, 98);
    targetStatusBar.command = 'simba.selectTargetWindow';
    targetStatusBar.tooltip = 'Simba target window - Click to change';
    updateTargetStatus();
    targetStatusBar.show();
    context.subscriptions.push(targetStatusBar);
}

/**
 * Update LSP status bar indicator
 * @param pathInfo - optional resolved path and whether it was auto-detected
 */
function updateLspStatus(state: 'starting' | 'running' | 'error' | 'disabled' | 'stopped', pathInfo?: { path: string; autoDetected: boolean }): void {
    if (!lspStatusBar) { return; }
    const source = pathInfo ? (pathInfo.autoDetected ? 'auto-detected' : 'configured') : '';
    const pathLine = pathInfo ? `\n${pathInfo.path} (${source})` : '';
    switch (state) {
        case 'starting':
            lspStatusBar.text = '$(sync~spin) Simba LSP';
            lspStatusBar.tooltip = `Simba LSP: Starting...${pathLine}\nClick to restart`;
            lspStatusBar.backgroundColor = undefined;
            break;
        case 'running':
            lspStatusBar.text = '$(check) Simba LSP';
            lspStatusBar.tooltip = `Simba LSP: Running${pathLine}\nClick to restart`;
            lspStatusBar.backgroundColor = undefined;
            break;
        case 'error':
            lspStatusBar.text = '$(error) Simba LSP';
            lspStatusBar.tooltip = `Simba LSP: Error${pathLine || '\nNo binary found'}\nClick to restart`;
            lspStatusBar.backgroundColor = new ThemeColor('statusBarItem.errorBackground');
            break;
        case 'disabled':
            lspStatusBar.text = '$(circle-slash) Simba LSP';
            lspStatusBar.tooltip = 'Simba LSP: Disabled in settings\nClick to restart';
            lspStatusBar.backgroundColor = undefined;
            break;
        case 'stopped':
            lspStatusBar.text = '$(circle-slash) Simba LSP';
            lspStatusBar.tooltip = 'Simba LSP: Stopped\nClick to restart';
            lspStatusBar.backgroundColor = undefined;
            break;
    }
}

/**
 * Update script status bar with running state and elapsed timer
 */
function updateScriptStatus(running: boolean, filename?: string, simbaPath?: string): void {
    if (!scriptStatusBar) { return; }
    if (running) {
        scriptStartTime = Date.now();
        scriptStatusBar.text = `$(play) Running: ${filename || 'script'}`;
        if (simbaPath) {
            const configuredRunPath = workspace.getConfiguration('simba').get<string>('runPath', '');
            const source = (configuredRunPath && configuredRunPath.length > 0 && fs.existsSync(configuredRunPath)) ? 'configured' : 'auto-detected';
            scriptStatusBar.tooltip = `Running: ${filename || 'script'}\nSimba: ${simbaPath} (${source})\nClick to stop`;
        } else {
            scriptStatusBar.tooltip = 'Running script - Click to stop';
        }
        scriptStatusBar.show();

        // Start elapsed timer
        if (scriptTimerInterval) { clearInterval(scriptTimerInterval); }
        scriptTimerInterval = setInterval(() => {
            if (scriptStartTime) {
                const elapsed = Math.floor((Date.now() - scriptStartTime) / 1000);
                const mins = Math.floor(elapsed / 60);
                const secs = elapsed % 60;
                const timeStr = mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
                scriptStatusBar.text = `$(play) Running: ${filename || 'script'} (${timeStr})`;
            }
        }, 1000);
    } else {
        scriptStartTime = undefined;
        if (scriptTimerInterval) {
            clearInterval(scriptTimerInterval);
            scriptTimerInterval = undefined;
        }
        scriptStatusBar.hide();
    }
}

/**
 * Update target window status bar
 */
function updateTargetStatus(): void {
    if (!targetStatusBar) { return; }
    if (selectedTargetWindow) {
        targetStatusBar.text = `$(window) ${selectedTargetWindow.title}`;
    } else {
        targetStatusBar.text = '$(window) No Target';
    }
}

/**
 * Update the scriptRunning context for menu visibility
 */
function setScriptRunning(running: boolean, filename?: string, simbaPath?: string): void {
    commands.executeCommand('setContext', 'simba.scriptRunning', running);
    updateScriptStatus(running, filename, simbaPath);
}

/**
 * Select target window from list of open windows
 */
async function selectTargetWindow(): Promise<void> {
    const windows = await getOpenWindows();

    // Create quick pick items
    const items: Array<{
        label: string;
        description: string;
        detail: string;
        window: WindowInfo | undefined;
        action?: string;
    }> = [];

    // Add option to enter handle manually (useful for child windows like SunAwtCanvas)
    items.push({
        label: '$(edit) Enter Handle Manually',
        description: 'Paste a window handle from Simba\'s target selector',
        detail: 'Use this for child windows (like Java canvas) that don\'t appear in the list',
        window: undefined,
        action: 'manual'
    });

    // Add option to clear target
    items.push({
        label: '$(x) Clear Target Window',
        description: 'Run scripts without a specific target',
        detail: '',
        window: undefined,
        action: 'clear'
    });

    // Add detected windows
    for (const w of windows) {
        items.push({
            label: w.title || '(Untitled)',
            description: w.processName ? `(${w.processName})` : '',
            detail: `Handle: ${w.handle}`,
            window: w
        });
    }

    const selected = await window.showQuickPick(items, {
        placeHolder: 'Select target window for Simba scripts',
        matchOnDescription: true,
        matchOnDetail: true
    });

    if (selected) {
        if (selected.action === 'manual') {
            // Get last entered values from global state
            const lastHandle = extensionContext?.globalState.get<string>('lastManualHandle', '');
            const lastPid = extensionContext?.globalState.get<string>('lastManualPid', '');

            // Prompt for manual handle input
            const handleInput = await window.showInputBox({
                prompt: 'Enter window handle (from Simba\'s target selector)',
                placeHolder: 'e.g., 13174842',
                value: lastHandle,
                valueSelection: lastHandle ? [0, lastHandle.length] : undefined,
                validateInput: (value) => {
                    if (!value) {
                        return 'Handle is required';
                    }
                    if (!/^\d+$/.test(value)) {
                        return 'Handle must be a number';
                    }
                    return null;
                }
            });

            if (handleInput) {
                // Save handle to global state
                await extensionContext?.globalState.update('lastManualHandle', handleInput);

                // Also prompt for PID (optional but recommended for WaspLib)
                const pidInput = await window.showInputBox({
                    prompt: 'Enter process ID (PID) - optional but recommended for WaspLib',
                    placeHolder: 'e.g., 24392 (leave empty if unknown)',
                    value: lastPid,
                    valueSelection: lastPid ? [0, lastPid.length] : undefined,
                    validateInput: (value) => {
                        if (value && !/^\d+$/.test(value)) {
                            return 'PID must be a number';
                        }
                        return null;
                    }
                });

                // Save PID to global state (even if empty)
                await extensionContext?.globalState.update('lastManualPid', pidInput || '');

                selectedTargetWindow = {
                    handle: handleInput,
                    title: `Manual (${handleInput})`,
                    processName: '',
                    pid: pidInput ? parseInt(pidInput, 10) : 0
                };
                updateTargetStatus();
                window.showInformationMessage(`Target window set to handle: ${handleInput}${pidInput ? `, PID: ${pidInput}` : ''}`);
            }
        } else if (selected.action === 'clear') {
            selectedTargetWindow = undefined;
            updateTargetStatus();
            window.showInformationMessage('Target window cleared');
        } else if (selected.window) {
            selectedTargetWindow = selected.window;
            updateTargetStatus();
            window.showInformationMessage(`Target window set to: ${selected.window.title}`);
        }
    }
}

// Track temp script file for cleanup
let tempScriptFile: string | undefined;

/**
 * Run the current Simba script
 */
async function runScript(): Promise<void> {
    // Check if a script is already running
    if (runningScript) {
        window.showWarningMessage('A Simba script is already running. Stop it first.');
        return;
    }

    // Get the current active editor
    const editor = window.activeTextEditor;
    if (!editor) {
        window.showErrorMessage('No active editor. Open a Simba script first.');
        return;
    }

    // Check if it's a Simba file
    const document = editor.document;
    if (document.languageId !== 'simba') {
        window.showErrorMessage('The current file is not a Simba script.');
        return;
    }

    // Save the document first
    if (document.isDirty) {
        await document.save();
    }

    // Find Simba binary
    const simbaPath = findSimbaForRun();
    if (!simbaPath) {
        window.showErrorMessage('Simba not found. Configure simba.runPath in settings.');
        return;
    }

    const scriptPath = document.uri.fsPath;
    const scriptDir = path.dirname(scriptPath);

    // Create or show the script output channel
    if (!scriptOutputChannel) {
        scriptOutputChannel = window.createOutputChannel('Simba Script Output');
    }
    scriptOutputChannel.clear();
    scriptOutputChannel.show(true);

    // Only show detailed info in verbose mode
    if (isVerboseEnabled()) {
        scriptOutputChannel.appendLine(`Running: ${scriptPath}`);
        if (selectedTargetWindow) {
            scriptOutputChannel.appendLine(`Target: ${selectedTargetWindow.title} (handle: ${selectedTargetWindow.handle}, PID: ${selectedTargetWindow.pid})`);
        }
        scriptOutputChannel.appendLine(`Simba: ${simbaPath}`);
    }

    // If target window selected and on Windows, use IPC bridge
    const USE_IPC = true;
    const scriptFilename = path.basename(scriptPath);
    if (selectedTargetWindow && os.platform() === 'win32' && USE_IPC) {
        logDebug('IPC Mode enabled for GetSimbaTargetWindow support');
        await runScriptWithIPC(simbaPath, scriptPath, scriptDir, selectedTargetWindow.handle, selectedTargetWindow.pid, scriptFilename);
    } else {
        logDebug('IPC Mode disabled, using --target parameter only');
        await runScriptDirect(simbaPath, scriptPath, scriptDir, scriptFilename);
    }
}

/**
 * Run script directly without IPC (simple mode)
 */
async function runScriptDirect(simbaPath: string, scriptPath: string, scriptDir: string, filename?: string): Promise<void> {
    const args: string[] = ['--run'];
    if (selectedTargetWindow) {
        args.push(`--target=${selectedTargetWindow.handle}`);
    }
    args.push(scriptPath);

    try {
        runningScript = spawn(simbaPath, args, {
            cwd: scriptDir
        });

        setScriptRunning(true, filename, simbaPath);

        runningScript.stdout?.on('data', (data: Buffer) => {
            scriptOutputChannel.append(data.toString());
        });

        runningScript.stderr?.on('data', (data: Buffer) => {
            scriptOutputChannel.append(data.toString());
        });

        runningScript.on('close', (code: number | null) => {
            // Only show exit info for errors or when verbose
            if (code !== 0 && code !== null) {
                scriptOutputChannel.appendLine(`Script exited with code ${code}.`);
            } else if (code === null) {
                scriptOutputChannel.appendLine('Script was stopped.');
            }

            runningScript = undefined;
            setScriptRunning(false);
        });

        runningScript.on('error', (err: Error) => {
            scriptOutputChannel.appendLine(`Error: ${err.message}`);
            runningScript = undefined;
            setScriptRunning(false);
        });

    } catch (error) {
        scriptOutputChannel.appendLine(`Failed to start script: ${error}`);
        runningScript = undefined;
        setScriptRunning(false);
    }
}

/**
 * Run script with IPC bridge (for GetSimbaTargetWindow support)
 * Uses PowerShell to create pipes and bridge communication
 */
async function runScriptWithIPC(simbaPath: string, scriptPath: string, scriptDir: string, targetHandle: string, targetPID: number, filename?: string): Promise<void> {
    // Create IPC server instance
    ipcServer = new SimbaIPCServer();
    ipcServer.setTargetWindow(targetHandle, targetPID);

    // Set script info for SCRIPT message responses
    const scriptName = path.basename(scriptPath);
    const scriptContent = fs.readFileSync(scriptPath, 'utf8');
    ipcServer.setScriptInfo(scriptName, scriptContent);

    // Generate PowerShell bridge script
    const psScript = getIPCBridgeScript(simbaPath, scriptPath, targetHandle);

    // Write to temp file (PowerShell has issues with very long command strings)
    const tempDir = os.tmpdir();
    tempScriptFile = path.join(tempDir, `simba_ipc_bridge_${Date.now()}.ps1`);
    fs.writeFileSync(tempScriptFile, psScript);

    try {
        // Spawn PowerShell with the bridge script
        runningScript = spawn('powershell.exe', [
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', tempScriptFile
        ], {
            cwd: scriptDir
        });

        setScriptRunning(true, filename, simbaPath);

        // Set up output stream for sending IPC responses back to C# via stdin
        if (runningScript.stdin) {
            ipcServer.setOutputStream(runningScript.stdin);
        }

        // stderr contains both IPC data (base64 with "IPC:" prefix) and debug output
        let stderrBuffer = '';
        runningScript.stderr?.on('data', (data: Buffer) => {
            stderrBuffer += data.toString();

            // Process complete lines
            let newlineIdx: number;
            while ((newlineIdx = stderrBuffer.indexOf('\n')) !== -1) {
                const line = stderrBuffer.substring(0, newlineIdx).replace(/\r$/, '');
                stderrBuffer = stderrBuffer.substring(newlineIdx + 1);

                if (line.startsWith('IPC:')) {
                    // This is IPC data - decode base64 and feed to IPC handler
                    try {
                        const base64Data = line.substring(4);
                        const binaryData = Buffer.from(base64Data, 'base64');
                        logDebug(`IPC decoded ${binaryData.length} bytes from base64`);
                        if (ipcServer) {
                            ipcServer.feedData(binaryData);
                        }
                    } catch (err) {
                        logDebug(`IPC failed to decode base64: ${err}`);
                    }
                } else if (line.startsWith('SIMBA:')) {
                    // Strip Simba debug flags (2 spaces + 6 hex chars) when not verbose
                    let content = line.substring(6);
                    if (!isVerboseEnabled()) {
                        content = stripSimbaDebugFlags(content);
                    }
                    if (content.trim()) {
                        scriptOutputChannel.appendLine(content);
                    }
                } else if (line.startsWith('ERROR:')) {
                    scriptOutputChannel.appendLine(`Error: ${line.substring(6)}`);
                } else if (line.startsWith('DEBUG:')) {
                    // Only show C# bridge debug messages when verbose is enabled
                    logDebug(line);
                } else if (line.trim()) {
                    // Skip empty lines
                    scriptOutputChannel.appendLine(line);
                }
            }
        });

        // stdout contains Simba's text output
        let stdoutBuffer = '';
        runningScript.stdout?.on('data', (data: Buffer) => {
            stdoutBuffer += data.toString();

            // Process complete lines
            let newlineIdx: number;
            while ((newlineIdx = stdoutBuffer.indexOf('\n')) !== -1) {
                const line = stdoutBuffer.substring(0, newlineIdx).replace(/\r$/, '');
                stdoutBuffer = stdoutBuffer.substring(newlineIdx + 1);

                // Strip Simba debug flags when verbose is off
                let content = line;
                if (!isVerboseEnabled()) {
                    content = stripSimbaDebugFlags(content);
                }
                if (content.trim()) {
                    scriptOutputChannel.appendLine(content);
                }
            }
        });

        runningScript.on('close', (code: number | null) => {
            // Only show exit info for errors or when verbose
            if (code !== 0 && code !== null) {
                scriptOutputChannel.appendLine(`Script exited with code ${code}.`);
            } else if (code === null) {
                scriptOutputChannel.appendLine('Script was stopped.');
            }

            // Cleanup
            if (ipcServer) {
                ipcServer.stop();
                ipcServer = undefined;
            }
            if (tempScriptFile && fs.existsSync(tempScriptFile)) {
                try { fs.unlinkSync(tempScriptFile); } catch {}
                tempScriptFile = undefined;
            }

            runningScript = undefined;
            setScriptRunning(false);
        });

        runningScript.on('error', (err: Error) => {
            scriptOutputChannel.appendLine(`Error: ${err.message}`);

            // Cleanup
            if (ipcServer) {
                ipcServer.stop();
                ipcServer = undefined;
            }
            if (tempScriptFile && fs.existsSync(tempScriptFile)) {
                try { fs.unlinkSync(tempScriptFile); } catch {}
                tempScriptFile = undefined;
            }

            runningScript = undefined;
            setScriptRunning(false);
        });

    } catch (error) {
        scriptOutputChannel.appendLine(`Failed to start script with IPC: ${error}`);

        // Cleanup
        if (ipcServer) {
            ipcServer.stop();
            ipcServer = undefined;
        }
        if (tempScriptFile && fs.existsSync(tempScriptFile)) {
            try { fs.unlinkSync(tempScriptFile); } catch {}
            tempScriptFile = undefined;
        }

        runningScript = undefined;
        setScriptRunning(false);
    }
}

/**
 * Stop the currently running Simba script
 */
function stopScript(): void {
    if (!runningScript) {
        window.showInformationMessage('No Simba script is currently running.');
        return;
    }

    scriptOutputChannel.appendLine('Stopping script...');

    // On Windows, we need to kill the entire process tree
    // because runningScript is PowerShell which spawned Simba
    if (os.platform() === 'win32' && runningScript.pid) {
        // Use taskkill to forcefully kill the process tree
        const taskkill = spawn('taskkill', ['/F', '/T', '/PID', runningScript.pid.toString()], {
            windowsHide: true
        });
        taskkill.on('close', () => {
            scriptOutputChannel.appendLine('Process tree killed.');
        });
        taskkill.on('error', () => {
            // Fallback to regular kill
            runningScript?.kill('SIGKILL');
        });
    } else {
        // On Unix, kill with SIGKILL
        runningScript.kill('SIGKILL');
    }

    // Cleanup
    if (ipcServer) {
        ipcServer.stop();
        ipcServer = undefined;
    }
    if (tempScriptFile && fs.existsSync(tempScriptFile)) {
        try { fs.unlinkSync(tempScriptFile); } catch {}
        tempScriptFile = undefined;
    }

    runningScript = undefined;
    setScriptRunning(false);
}

/**
 * Task provider for Simba compile and run tasks
 */
interface SimbaTaskDefinition extends TaskDefinition {
    task: 'run' | 'compile';
    file?: string;
}

class SimbaTaskProvider implements TaskProvider {
    provideTasks(): Task[] {
        return [
            this.createTask('compile', 'simba: compile'),
            this.createTask('run', 'simba: run')
        ];
    }

    resolveTask(task: Task): Task | undefined {
        const definition = task.definition as SimbaTaskDefinition;
        if (definition.task) {
            return this.createTask(definition.task, task.name, definition.file);
        }
        return undefined;
    }

    private createTask(taskType: 'run' | 'compile', name: string, file?: string): Task {
        const definition: SimbaTaskDefinition = { type: 'simba', task: taskType, file };
        const simbaPath = findSimbaForRun() || 'Simba';
        const filePath = file || '${file}';
        const flag = taskType === 'compile' ? '--compile' : '--run';
        const execution = new ShellExecution(`"${simbaPath}" ${flag} "${filePath}"`);
        const task = new Task(definition, TaskScope.Workspace, name, 'simba', execution, '$simba');
        if (taskType === 'compile') {
            task.group = TaskGroup.Build;
        }
        return task;
    }
}

/**
 * Extension activation
 */
export async function activate(context: ExtensionContext): Promise<void> {
    extensionContext = context;
    outputChannel = window.createOutputChannel('Simba Language Server');
    outputChannel.appendLine('Simba Language Support extension activated');

    // Register commands
    context.subscriptions.push(
        commands.registerCommand('simba.restartServer', () => restartLanguageServer(context)),
        commands.registerCommand('simba.runScript', runScript),
        commands.registerCommand('simba.stopScript', stopScript),
        commands.registerCommand('simba.selectTargetWindow', selectTargetWindow),
        commands.registerCommand('simba.openWalkthrough', () => {
            commands.executeCommand('workbench.action.openWalkthrough',
                'villavu.simba-lang#simba-getting-started', false);
        })
    );

    // Auto-open walkthrough on first install
    if (!context.globalState.get<boolean>('walkthroughShown', false)) {
        context.globalState.update('walkthroughShown', true);
        commands.executeCommand('workbench.action.openWalkthrough',
            'villavu.simba-lang#simba-getting-started', true);
    }

    // Register task provider
    context.subscriptions.push(
        tasks.registerTaskProvider('simba', new SimbaTaskProvider())
    );

    // Create status bar items
    createStatusBarItems(context);

    // Initialize script running state
    setScriptRunning(false);

    // Check if LSP is enabled
    const lspEnabled = workspace.getConfiguration('simba').get<boolean>('lsp.enabled', true);

    if (lspEnabled) {
        await startLanguageServer(context);
    } else {
        outputChannel.appendLine('LSP is disabled in settings');
        updateLspStatus('disabled');
    }

    // Watch for configuration changes
    context.subscriptions.push(
        workspace.onDidChangeConfiguration(async (e) => {
            if (e.affectsConfiguration('simba.lsp')) {
                const newLspEnabled = workspace.getConfiguration('simba').get<boolean>('lsp.enabled', true);
                if (newLspEnabled && !client) {
                    await startLanguageServer(context);
                } else if (!newLspEnabled && client) {
                    await stopLanguageServer();
                    updateLspStatus('disabled');
                } else if (newLspEnabled && client) {
                    // Path might have changed, restart
                    await restartLanguageServer(context);
                }
            }
        })
    );
}

/**
 * Extension deactivation
 */
export async function deactivate(): Promise<void> {
    // Clear script timer
    if (scriptTimerInterval) {
        clearInterval(scriptTimerInterval);
        scriptTimerInterval = undefined;
    }

    // Stop any running script
    if (runningScript) {
        runningScript.kill();
        runningScript = undefined;
    }

    await stopLanguageServer();
}
