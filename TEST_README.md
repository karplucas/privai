# PrivAI Testing Documentation

This document describes the comprehensive testing suite for the PrivAI Flutter application.

## Test Structure

### Unit Tests (`test/unit_test.dart`)
- Core functionality tests for message validation and UI components
- Widget tests for UI behavior and user interactions
- Message flow tests for chat functionality
- Multilingual support validation

### Widget Tests (`test/widget_test.dart`)
- Basic app startup and UI component tests
- User interaction tests (text input, button presses)
- State management tests for recording functionality

### Integration Tests (`integration_test/app_test.dart`)
- End-to-end user journey tests
- Complete chat session simulations
- UI responsiveness and layout tests
- Error handling and input validation

### Multilingual Tests (`test/multilingual_test.dart`)
- Language code validation
- TTS voice configuration tests
- Speech recognition accuracy expectations
- Multilingual conversation scenarios

## Running Tests

### Run All Tests
```bash
flutter test
```

### Run Specific Test Files
```bash
flutter test test/widget_test.dart
flutter test test/unit_test.dart
flutter test test/multilingual_test.dart
```

### Run Integration Tests
```bash
flutter test integration_test/app_test.dart
```

### Run Tests with Coverage
```bash
flutter test --coverage
```

## Test Categories

### 1. Widget Tests
- App initialization and loading states
- UI component presence and functionality
- User input handling (text fields, buttons)
- State transitions (recording on/off)

### 2. Unit Tests
- Business logic validation
- Message processing
- Language code validation
- Audio file path generation

### 3. Integration Tests
- Complete user workflows
- Multi-step interactions
- Error scenarios
- Performance validation

### 4. Multilingual Tests
- Language support validation
- TTS configuration testing
- Speech recognition expectations
- Cross-language functionality

## Key Test Features

### Message Flow Testing
- Empty message rejection
- Valid message acceptance
- Message history maintenance
- UI updates after sending

### Audio Functionality Testing
- Recording state transitions
- UI feedback during recording
- Button state changes
- Error handling

### Multilingual Support Testing
- Support for 80+ languages via Whisper
- TTS voice configurations for multiple languages
- Language detection validation
- Quality metrics for different languages

### UI Responsiveness Testing
- Layout adaptation
- Component visibility
- Touch target accessibility
- Visual feedback

## Mock Dependencies

The tests use mockito for external dependencies:
- WhisperController (speech-to-text)
- AudioPlayer (audio playback)
- SherpaOnnxOfflineTts (text-to-speech)
- AudioRecorder (audio recording)

## Test Data

Tests include realistic test data for:
- Sample chat messages in multiple languages
- Expected AI responses
- Audio file paths
- Language codes and names
- TTS configuration parameters

## Continuous Integration

These tests are designed to run in CI/CD pipelines and provide:
- Fast feedback on code changes
- Regression prevention
- Quality assurance for multilingual features
- UI stability validation